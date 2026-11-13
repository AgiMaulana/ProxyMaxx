import Foundation
import Branding
import os

/// The minimal plugin runtime for Phase 1 (docs/plugin-store-phase1.md).
///
/// Spawns a plugin's entry point with a JSON-lines stdio contract:
///
///   plugin → host: {"kind":"permission.request","permissionId":"local-map.read"}
///   host → plugin: {"kind":"permission.status","permissionId":"local-map.read","status":"GRANTED"}
///
/// The runner lives inside the app process, so every permission request it relays is
/// attributed to the plugin it spawned — a plugin process can never speak for another
/// plugin, and no plugin-writable file is ever trusted as identity evidence. Future
/// SDK surfaces (Local Override APIs, more message kinds) should extend this
/// protocol rather than introducing a second channel.
///
/// One malformed or unknown line terminates the plugin: the contract is strict so a
/// chatty plugin cannot smuggle state past the host.
@MainActor
public final class PluginRunner: ObservableObject {
    public enum PluginRunnerError: Error, Equatable {
        case alreadyRunning(String)
        case entryPointMissing(String)
        case launchFailed(String)
    }

    public struct RunState: Equatable, Sendable {
        public let pluginID: String
        public let pid: Int32
        public let startedAt: Date
    }

    @Published public private(set) var runningPlugins: [String: RunState] = [:]
    /// Last observed exit per plugin, for the details view.
    @Published public private(set) var lastExitDescription: [String: String] = [:]

    private let permissionManager: PermissionManager
    private var processes: [String: Process] = [:]
    /// In-flight consent requests keyed by the plugin's `requestId`, so a
    /// `permission.cancel` message can resolve the pending request.
    private var inflightRequests: [String: Task<PluginPermissionStatus, Never>] = [:]
    /// Request ids already answered with `permission.cancelled`; their late
    /// consent resolution is ignored.
    private var cancelledRequests: Set<String> = []
    private nonisolated static let lineLimitBytes = 1_048_576

    // Protocol v1 (Docs/PROTOCOL.md in the ProxyMaxx Plugin SDK).
    private static let kindPermissionRequest = "permission.request"
    private static let kindPermissionRequestAll = "permission.requestAll"
    private static let kindPermissionCheck = "permission.check"
    private static let kindPermissionCheckAll = "permission.checkAll"
    private static let kindPermissionCancel = "permission.cancel"
    private static let kindPermissionStatus = "permission.status"
    private static let kindPermissionStatuses = "permission.statuses"
    private static let kindPermissionCancelled = "permission.cancelled"
    private static let kindPermissionError = "permission.error"

    struct PluginRequestMessage: Decodable {
        let kind: String
        let requestId: String?
        let permissionId: String?
        let permissionIds: [String]?
    }

    struct StatusReply: Encodable {
        let kind = "permission.status"
        let requestId: String
        let status: String
    }

    struct StatusesReply: Encodable {
        let kind = "permission.statuses"
        let requestId: String
        let statuses: [String: String]
    }

    struct CancelledReply: Encodable {
        let kind = "permission.cancelled"
        let requestId: String
    }

    struct ErrorReply: Encodable {
        let kind = "permission.error"
        let requestId: String
        let error: String
    }

    public init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    public func isRunning(_ pluginID: String) -> Bool {
        processes[pluginID]?.isRunning ?? false
    }

    public func runState(for pluginID: String) -> RunState? {
        runningPlugins[pluginID]
    }

    /// Spawn a plugin's entry point. The manifest was validated at install time; the
    /// executable must exist and be executable in the installed package. Extra
    /// arguments are passed through verbatim after the entry-point path.
    public func start(_ plugin: InstalledPlugin, registry: PluginRegistry, arguments: [String] = []) throws {
        let pluginID = plugin.manifest.id
        guard processes[pluginID] == nil else {
            throw PluginRunnerError.alreadyRunning(pluginID)
        }
        let executable = registry.entryPointURL(for: plugin)
        let installDirectory = registry.installationDirectory(for: pluginID)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw PluginRunnerError.entryPointMissing(executable.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PluginRunnerError.entryPointMissing("Entry point is not executable: \(executable.path)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = installDirectory
        process.environment = [
            "PROXYMAXX_PLUGIN_ID": pluginID,
            "PROXYMAXX_SDK_VERSION": PluginSDK.version,
            "PROXYMAXX_PLUGIN_DIR": installDirectory.path,
            "PROXYMAXX_SUPPORT_DIR": Brand.supportDirectory.path,
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // A plugin that fills its stderr pipe would block forever on write; drain it
        // in the background and keep a tail for the exit description.
        let stderrTail = StderrTail()
        pumpStderr(stderrPipe.fileHandleForReading, into: stderrTail)

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            let stderrText = stderrTail.text
            Task { @MainActor [weak self] in
                self?.processes.removeValue(forKey: pluginID)
                self?.runningPlugins.removeValue(forKey: pluginID)
                // A host-initiated termination already recorded its reason (strict
                // contract enforcement); keep that over the plain signal report.
                let hostRecorded = self?.lastExitDescription[pluginID]?.hasPrefix("Terminated:") ?? false
                if !hostRecorded {
                    self?.lastExitDescription[pluginID] = Self.exitDescription(
                        status: status, reason: reason, stderrText: stderrText
                    )
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw PluginRunnerError.launchFailed("\(pluginID): \(error.localizedDescription)")
        }
        processes[pluginID] = process
        runningPlugins[pluginID] = RunState(
            pluginID: pluginID, pid: process.processIdentifier, startedAt: Date()
        )

        pumpStdout(
            stdoutPipe.fileHandleForReading,
            stdin: stdinPipe.fileHandleForWriting,
            pluginID: pluginID
        )
    }

    /// Ask a plugin to stop: SIGTERM first, escalate to SIGKILL if it lingers.
    public func stop(_ pluginID: String) {
        guard let process = processes[pluginID], process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }

    public func stopAll() {
        for pluginID in processes.keys {
            stop(pluginID)
        }
    }

    // MARK: - Message pump

    /// Event-driven stdout pump: `readabilityHandler` fires as data arrives, so the
    /// pump never blocks a cooperative-pool thread waiting on a pipe.
    private func pumpStdout(_ stdout: FileHandle, stdin: FileHandle, pluginID: String) {
        let buffer = LineBuffer(limit: Self.lineLimitBytes)
        stdout.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = buffer.append(chunk)
            for lineData in lines {
                guard let line = String(data: lineData, encoding: .utf8) else {
                    Task { @MainActor [weak self] in
                        self?.terminate(pluginID, reason: "message was not valid UTF-8")
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handleLine(line, pluginID: pluginID, stdin: stdin)
                }
            }
            if buffer.isOverLimit {
                Task { @MainActor [weak self] in
                    self?.terminate(pluginID, reason: "message exceeded \(Self.lineLimitBytes) bytes")
                }
            }
        }
    }

    private func pumpStderr(_ stderr: FileHandle, into tail: StderrTail) {
        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            tail.append(chunk)
        }
    }

    private func handleLine(_ line: String, pluginID: String, stdin: FileHandle) async {
        guard let data = line.data(using: .utf8) else {
            terminate(pluginID, reason: "message was not valid UTF-8")
            return
        }
        let request: PluginRequestMessage
        do {
            request = try JSONDecoder().decode(PluginRequestMessage.self, from: data)
        } catch {
            terminate(pluginID, reason: "malformed message: \(error.localizedDescription)")
            return
        }
        // Every protocol v1 request carries a requestId; replies correlate with it.
        guard let requestId = request.requestId, !requestId.isEmpty else {
            terminate(pluginID, reason: "message without requestId")
            return
        }
        // A request cancelled by the plugin must never be answered later by a
        // consent resolution that raced with the cancellation.
        defer { cancelledRequests.remove(requestId) }

        switch request.kind {
        case Self.kindPermissionRequest:
            guard let permissionID = request.permissionId else {
                terminate(pluginID, reason: "permission.request without permissionId")
                return
            }
            let task = Task { await permissionManager.request(pluginID: pluginID, permissionID: permissionID) }
            inflightRequests[requestId] = task
            let status = await task.value
            guard inflightRequests.removeValue(forKey: requestId) != nil,
                  !cancelledRequests.contains(requestId) else {
                return // cancelled by the plugin; the cancelled reply already went out
            }
            if status == .notRequested {
                // Spec §6: a completed request must never surface NOT_REQUESTED —
                // report an unrecoverable failure so the SDK fails closed.
                sendReply(
                    ErrorReply(requestId: requestId, error: "unresolvedRequest"),
                    stdin: stdin, pluginID: pluginID
                )
                return
            }
            sendReply(StatusReply(requestId: requestId, status: status.rawValue), stdin: stdin, pluginID: pluginID)

        case Self.kindPermissionRequestAll:
            guard let permissionIDs = request.permissionIds, !permissionIDs.isEmpty else {
                terminate(pluginID, reason: "permission.requestAll without permissionIds")
                return
            }
            // One batch operation: one decision per permission, resolved in input
            // order. Distinct-permission consent experiences are not grouped yet;
            // coalescing still merges concurrent requests for the same permission.
            var statuses: [String: String] = [:]
            for permissionID in permissionIDs {
                let status = await permissionManager.request(pluginID: pluginID, permissionID: permissionID)
                statuses[permissionID] = status.rawValue
            }
            sendReply(StatusesReply(requestId: requestId, statuses: statuses), stdin: stdin, pluginID: pluginID)

        case Self.kindPermissionCheck:
            guard let permissionID = request.permissionId else {
                terminate(pluginID, reason: "permission.check without permissionId")
                return
            }
            let status = permissionManager.status(pluginID: pluginID, permissionID: permissionID)
            sendReply(StatusReply(requestId: requestId, status: status.rawValue), stdin: stdin, pluginID: pluginID)

        case Self.kindPermissionCheckAll:
            guard let permissionIDs = request.permissionIds else {
                terminate(pluginID, reason: "permission.checkAll without permissionIds")
                return
            }
            let statuses = Dictionary(uniqueKeysWithValues: permissionIDs.map { id in
                (id, permissionManager.status(pluginID: pluginID, permissionID: id).rawValue)
            })
            sendReply(StatusesReply(requestId: requestId, statuses: statuses), stdin: stdin, pluginID: pluginID)

        case Self.kindPermissionCancel:
            // Plugin-initiated cancellation resolves as cancellation; no decision
            // is recorded for the request itself (spec §7.2). The consent task is
            // cancelled; the runner no longer waits on it.
            inflightRequests.removeValue(forKey: requestId)?.cancel()
            cancelledRequests.insert(requestId)
            sendReply(CancelledReply(requestId: requestId), stdin: stdin, pluginID: pluginID)

        default:
            // Forward compatibility: unknown request kinds are ignored.
            os_log_debug(pluginID, "ignoring unknown message kind '\(request.kind)'")
        }
    }

    /// Encodes and writes one protocol v1 reply line to the plugin's stdin.
    private func sendReply(_ value: some Encodable, stdin: FileHandle, pluginID: String) {
        guard let payload = try? JSONEncoder().encode(value) else {
            terminate(pluginID, reason: "host could not encode a response")
            return
        }
        var outgoing = payload
        outgoing.append(0x0A)
        do {
            try stdin.write(contentsOf: outgoing)
        } catch {
            // Broken pipe means the plugin exited mid-request; the termination
            // handler records that.
            os_log_debug(pluginID, "could not write response: \(error.localizedDescription)")
        }
    }

    /// Strict contract: one bad line ends the plugin.
    private func terminate(_ pluginID: String, reason: String) {
        os_log_debug(pluginID, "terminating plugin: \(reason)")
        lastExitDescription[pluginID] = "Terminated: \(reason)"
        guard let process = processes[pluginID], process.isRunning else { return }
        process.terminate()
    }

    static func exitDescription(status: Int32, reason: Process.TerminationReason, stderrText: String) -> String {
        switch reason {
        case .uncaughtSignal:
            let name = status == 2 ? " (interrupt)" : status == 15 ? " (terminated)" : ""
            return "Exited on signal \(status)\(name)"
        case .exit:
            if status == 0 { return "Exited normally" }
            let tail = stderrText.isEmpty ? "" : " — \(stderrText)"
            return "Exited with status \(status)\(tail)"
        @unknown default:
            return "Exited (reason \(reason.rawValue), status \(status))"
        }
    }
}

/// Accumulates pipe bytes and splits complete newline-terminated lines, bounding
/// how much may sit in the buffer between newlines. A class so the readability
/// handler can capture and mutate it across callbacks.
final class LineBuffer {
    private let limit: Int
    private var pending = Data()

    init(limit: Int) {
        self.limit = limit
    }

    /// Append a chunk; returns every complete line it completed.
    func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(line)
        }
        return lines
    }

    /// True when the buffer holds more than one message is allowed to occupy.
    var isOverLimit: Bool {
        pending.count > limit
    }
}

/// Bounded tail of a plugin's stderr, shown when the plugin exits with a status.
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes = 4_096

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}

private func os_log_debug(_ pluginID: String, _ message: String) {
    Logger(subsystem: Brand.bundleIdentifier, category: "plugin-runner").debug("\(pluginID, privacy: .public): \(message, privacy: .public)")
}
