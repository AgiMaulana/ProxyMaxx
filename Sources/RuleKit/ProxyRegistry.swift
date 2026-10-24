import Foundation
import Darwin
import Branding

/// Who currently owns the listening proxy: the GUI app (`ProxyMaxx`) or the CLI
/// (`proxymaxx-cli serve`).
///
/// Both write the same small JSON file under `Application Support/ProxyMaxx/` right
/// after their engine binds, and both erase it when they stop. Any other piece of the
/// tool — the GUI noticing a CLI-run proxy, or the CLI refusing to start a second
/// engine — reads this file instead of probing ports. Readers treat a dead `pid` as a
/// missing entry so a crash never leaves a ghost owner.
///
/// This mirrors ProxyMaxx's CLI↔app setup: one engine, one owner, and clients that
/// attach rather than bind.
public struct ProxyRegistryEntry: Codable, Equatable, Sendable {
    public enum Owner: String, Codable, Sendable {
        case app
        case cli
    }

    public var owner: Owner
    /// Process id of the writer, so readers can detect a stale entry after a crash.
    public var pid: Int
    public var httpPort: Int
    /// SOCKS port when the engine was started with one.
    public var socksPort: Int?
    public var startedAt: Date

    public init(owner: Owner, pid: Int, httpPort: Int, socksPort: Int?, startedAt: Date = Date()) {
        self.owner = owner
        self.pid = pid
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.startedAt = startedAt
    }
}

public enum ProxyRegistry {
    /// Both directions pinned to seconds-since-1970. Swift's defaults encode from 1970
    /// but decode from the 2001 reference date, so an unpinned round-trip skews every
    /// timestamp by 978307160 s — which would push CommandIPC `createdAt` into the
    /// future and permanently disable stale-request expiry.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Same folder the rule file lives in, so one location covers the whole contract.
    public static var defaultDirectory: URL {
        Brand.supportDirectory
    }

    static func url(directory: URL?) -> URL {
        (directory ?? defaultDirectory).appendingPathComponent("proxy-registry.json")
    }

    /// The current owner, or nil when nothing is serving. A `pid` that no longer exists
    /// is treated as a leftover from a crashed run, not as an owner.
    public static func read(directory: URL? = nil) -> ProxyRegistryEntry? {
        let fileURL = url(directory: directory)
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? decoder.decode(ProxyRegistryEntry.self, from: data),
              pidAlive(entry.pid)
        else { return nil }
        return entry
    }

    /// Publish ownership. Called with the bound engine's ports right after binding.
    public static func write(_ entry: ProxyRegistryEntry, directory: URL? = nil) throws {
        let fileURL = url(directory: directory)
        let data = try encoder.encode(entry)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    /// Remove the ownership record. Writers call this when their engine stops; if the
    /// writer crashes instead, `read()` notices the dead pid on the next read.
    public static func clear(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: url(directory: directory))
    }

    /// True when the process exists right now. `kill(pid, 0)` succeeds for any process
    /// this user owns, whether or not it is the proxy — good enough, since pids match
    /// the writer and collisions only matter within a presence window.
    static func pidAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}

/// File-backed command channel between `proxymaxx-cli rule …` and the GUI's engine, used
/// only when the GUI (`owner = .app`) is serving. Layout:
///
/// `…/ProxyMaxx/ipc/request-<uuid>.json`   written by the CLI, waiting to be consumed
/// `…/ProxyMaxx/ipc/response-<id>.json`    written by the app, read once by the CLI
///
/// Mirrors ProxyMaxx's `ProxyMaxxCLIIPCFileStore` + Command request/response notification
/// pair, with a polling reader instead of cross-process notifications. Requests older
/// than `staleAfter` are dropped on read so a vanished CLI never leaves work behind.
public enum CommandIPC {
    public static var defaultDirectory: URL {
        ProxyRegistry.defaultDirectory.appendingPathComponent("ipc", isDirectory: true)
    }

    /// Requests older than this are expired instead of executed.
    public static let staleAfter: TimeInterval = 60

    public struct Message: Codable, Equatable {
        public let id: String
        public let op: Operation
        /// `add`: the complete rule to insert at the end of the list.
        public let rule: MapLocalRule?
        /// Selector for `remove`, `enable`, `disable`; first present field wins.
        public let targetID: String?
        public let targetName: String?
        public let targetURL: String?
        /// `move`: signed positions between the rule and its now-neighbour.
        public let by: Int?
        /// `setToolEnabled`: which tool's master switch to flip (`map-local`, `ssl-proxying`).
        public let tool: String?
        /// `setToolEnabled`: the desired switch state.
        public let enabled: Bool?
        /// `setSSLProxying`: `include` or `exclude`.
        public let list: String?
        /// `setSSLProxying`: the pattern to add or remove.
        public let pattern: String?
        /// `setSSLProxying`: true adds the pattern, false removes it.
        public let add: Bool?
        /// `addScenario`: the complete scenario to save.
        public let scenario: MapLocalScenario?
        public let createdAt: Date

        public init(
            op: Operation,
            rule: MapLocalRule? = nil,
            targetID: String? = nil,
            targetName: String? = nil,
            targetURL: String? = nil,
            by: Int? = nil,
            tool: String? = nil,
            enabled: Bool? = nil,
            list: String? = nil,
            pattern: String? = nil,
            add: Bool? = nil,
            scenario: MapLocalScenario? = nil
        ) {
            self.id = UUID().uuidString
            self.op = op
            self.rule = rule
            self.targetID = targetID
            self.targetName = targetName
            self.targetURL = targetURL
            self.by = by
            self.tool = tool
            self.enabled = enabled
            self.list = list
            self.pattern = pattern
            self.add = add
            self.scenario = scenario
            self.createdAt = Date()
        }
    }

    public struct Result: Codable, Equatable {
        public let id: String
        public let ok: Bool
        public let error: String?
        public let rule: MapLocalRule?
        /// `activateScenario`: how many existing rules the scenario enabled.
        public let applied: Int?
        /// `listScenarios`: the app's live scenarios and rules, so a read never waits for
        /// the app's debounced autosave to reach the rule file.
        public let scenarios: [MapLocalScenario]?
        public let rules: [MapLocalRule]?

        public init(
            id: String,
            ok: Bool,
            error: String? = nil,
            rule: MapLocalRule? = nil,
            applied: Int? = nil,
            scenarios: [MapLocalScenario]? = nil,
            rules: [MapLocalRule]? = nil
        ) {
            self.id = id
            self.ok = ok
            self.error = error
            self.rule = rule
            self.applied = applied
            self.scenarios = scenarios
            self.rules = rules
        }
    }

    public enum Operation: String, Codable, Sendable {
        case add
        /// Replace a rule, matched by the id of the carried rule. The CLI's counterpart
        /// of `add` for edits, so the app's live engine sees the change without a restart.
        case update
        case remove
        case enable
        case disable
        case move
        case clear
        /// Flip a tool's master switch (`tool` names it, `enabled` is the target state).
        case setToolEnabled
        /// Add or remove one SSL Proxying include/exclude pattern.
        case setSSLProxying
        /// Empty the app's current session. Only meaningful while the app owns the engine.
        case clearSession
        /// Save or replace a named Map Local scenario, carried in `scenario`.
        case addScenario
        /// Delete a scenario, selected by id or name.
        case removeScenario
        /// Turn on exactly one scenario's rules, selected by id or name.
        case activateScenario
        /// Read the live scenarios and rules without touching the rule file.
        case listScenarios
    }

    static func directory(_ directory: URL?) -> URL {
        directory ?? defaultDirectory
    }

    // MARK: - CLI side

    /// Write the request and wait for the consumer's response file.
    /// Returns nil on timeout — the consumer may not be running after all.
    public static func request(
        _ message: Message,
        directory: URL? = nil,
        timeout: TimeInterval = 5
    ) -> Result? {
        let base = self.directory(directory)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch { return nil }
        let requestURL = base.appendingPathComponent("request-\(message.id).json")
        guard let data = try? ProxyRegistry.encoder.encode(message),
              (try? data.write(to: requestURL, options: .atomic)) != nil
        else { return nil }

        let responseURL = base.appendingPathComponent("response-\(message.id).json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let result = try? ProxyRegistry.decoder.decode(Result.self, from: data) {
                try? FileManager.default.removeItem(at: responseURL)
                try? FileManager.default.removeItem(at: requestURL)
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: requestURL)
        return nil
    }

    // MARK: - Consumer side (the GUI)

    /// Pending requests, oldest first. Only files this user owns inside the IPC
    /// directory are considered, and stale ones are deleted silently — a CLI that died
    /// before its request was picked up must not later mutate the engine.
    public static func pendingMessages(directory: URL? = nil) -> [(url: URL, message: Message)] {
        let base = self.directory(directory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        var stale: [URL] = []
        var pending: [(URL, Message)] = []

        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.lastPathComponent.hasPrefix("request-") else { continue }
            guard FileManager.default.fileExists(atPath: url.path),
                  isOwnedByCurrentUser(at: url)
            else { continue }
            guard let data = try? Data(contentsOf: url),
                  let message = try? ProxyRegistry.decoder.decode(Message.self, from: data)
            else { stale.append(url); continue }

            if Date().timeIntervalSince(message.createdAt) > staleAfter {
                stale.append(url)
            } else {
                pending.append((url, message))
            }
        }
        for url in stale { try? FileManager.default.removeItem(at: url) }
        return pending
    }

    /// Publish the outcome for the CLI that is waiting on this request.
    public static func respond(_ result: Result, directory: URL? = nil) throws {
        let base = self.directory(directory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let data = try ProxyRegistry.encoder.encode(result)
        try data.write(
            to: base.appendingPathComponent("response-\(result.id).json"),
            options: .atomic
        )
    }

    /// Refuse payloads that live outside the IPC directory or that some other user
    /// owns — the same check ProxyMaxx runs on its CLI IPC payload.
    static func isOwnedByCurrentUser(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard let owner = attributes[FileAttributeKey.ownerAccountName] as? String else { return false }
        return owner == NSUserName()
    }
}
