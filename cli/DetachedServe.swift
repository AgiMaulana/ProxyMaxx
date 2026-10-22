import Foundation
import RuleKit

/// `serve --detach`: start the engine in a background copy of this command and return,
/// turning "blocks forever streaming" into fire-and-forget for an agent.
///
/// This is a flag on `serve`, not a second `start` verb, on purpose. There is one engine
/// and one way to start it; `--detach` only decides whether this process is also the one
/// reading stdout. The background copy inherits every other flag (ports, rule file,
/// session log), so nothing about the run differs except who waits.
enum DetachedServe {
    static func launch() throws {
        guard let executable = Bundle.main.executablePath else {
            throw CLIError("could not locate the proxymaxx-cli executable to detach")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Re-run the very command the user typed (including `serve … --detach`); the
        // PROXYMAXX_DETACHED marker is what stops the child from detaching again.
        process.arguments = Array(CommandLine.arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PROXYMAXX_DETACHED"] = "1"
        process.environment = environment

        let logURL = ServeLog.logURL
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        // Detached stdout carries nothing a caller is watching: flows go to the durable
        // session log, and the NDJSON stream would only be noise. Stderr keeps the
        // startup notices and engine diagnostics, so a failed background run is auditable.
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        guard let errorHandle = try? FileHandle(forWritingTo: logURL) else {
            throw CLIError("could not open \(logURL.path) for the detached proxy's log")
        }
        _ = try? errorHandle.seekToEnd()
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw CLIError("could not start the detached proxy: \(error)")
        }

        // Don't answer until the child has actually bound and published itself, so
        // `serve --detach && proxymaxx-cli flows` never races the engine coming up.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !process.isRunning { break }
            if let entry = ProxyRegistry.read(), entry.pid == Int(process.processIdentifier) {
                print(statusLine(for: entry))
                note("detached on 127.0.0.1:\(entry.httpPort) (pid \(entry.pid)); log \(logURL.path); stop with `proxymaxx-cli stop`")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError("the detached proxy did not come up; see \(logURL.path)")
    }

    private static func statusLine(for entry: ProxyRegistryEntry) -> String {
        let socks: Any = entry.socksPort ?? NSNull()
        let object: [String: Any] = [
            "ok": true,
            "owner": entry.owner.rawValue,
            "pid": entry.pid,
            "httpPort": entry.httpPort,
            "socksPort": socks,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
