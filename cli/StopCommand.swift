import Foundation
import RuleKit
import Darwin

/// `proxymaxx-cli stop`: ask whichever process owns the engine to shut down. Reads the pid
/// from the registry, so it signals the process this tool started rather than grabbing a
/// port, and it is idempotent — stopping when nothing runs succeeds, which is what lets
/// an agent bracket its work with an unconditional `serve … ; stop`.
enum StopCommand {
    static func run(_ arguments: Arguments) throws {
        guard let entry = ProxyRegistry.read() else {
            note("no proxy is running")
            StatusCommand.printCurrent()
            return
        }

        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        if entry.pid == selfPID {
            throw CLIError("refusing to stop the process running this command")
        }

        let force = arguments.has("force")
        let signal = force ? SIGKILL : SIGTERM
        if kill(pid_t(entry.pid), signal) != 0, errno != ESRCH {
            throw CLIError("could not signal pid \(entry.pid) (errno \(errno))")
        }
        note("asked the \(entry.owner == .cli ? "ProxyMaxx CLI" : "app") (pid \(entry.pid)) to stop")

        // A clean shutdown clears the registry; a killed process leaves it, but the dead
        // pid makes ProxyRegistry.read() report nothing either way.
        let deadline = Date().addingTimeInterval(force ? 3 : 6)
        while Date() < deadline {
            if ProxyRegistry.read() == nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if ProxyRegistry.read() != nil, !force {
            note("pid \(entry.pid) is still running; retry with `proxymaxx-cli stop --force`")
            exit(ExitCode.failure)
        }
        note("stopped")
        StatusCommand.printCurrent()
    }
}
