import Foundation
import os

#if canImport(AppKit)
import AppKit
#endif

/// Opens a fresh Terminal window that already has `proxymaxx-cli` on `PATH`.
///
/// The app cannot put the tool on `PATH` for the terminals the user already has open — only
/// their own shells can do that — so the sheet's button does the next best thing: it starts
/// one terminal that is set up correctly, which is enough to run the tool immediately.
///
/// Two paths, because a bundled app is the norm but a `swift run` checkout is not. A bundled
/// app delegates to `proxymaxx-cli export`, so the profile and the current session are
/// prepared by the same code the CLI users run. A checkout has no bundle to export, so the
/// window just gets a temporary `PATH` entry and nothing is written to disk.
public enum TerminalLauncher {
    public enum LaunchError: Error, CustomStringConvertible {
        case terminalUnavailable
        case appleScriptFailed(number: Int, message: String)

        public var description: String {
            switch self {
            case .terminalUnavailable:
                return "Terminal could not be opened"
            case .appleScriptFailed(let number, let message):
                return "Terminal could not be opened: \(message) (\(number))"
            }
        }
    }

    private static let log = Logger(subsystem: "com.proxymaxx.app", category: "TerminalLauncher")

    /// What the new window is for. The two buttons promise different things, so they must not
    /// run the same script.
    public enum Intent {
        /// `PATH` for that one window only; the shell profile is left alone.
        case thisSessionOnly
        /// A marked block in the shell profile, so every later terminal finds the tool.
        case permanently
    }

    /// The shell script the new window runs before handing control back to the user.
    ///
    /// Kept separate from the launching code so it can be asserted in tests: the command
    /// substitution is deliberately single-quoted, because a bundle under
    /// `~/Applications/My Apps` would otherwise be re-split by the shell.
    ///
    /// A session-only window ends by starting a login shell, which reads the profile and
    /// inherits the updated `PATH`. Without it Terminal closes the window the moment the
    /// script exits, so the user would get a flash instead of a terminal. A permanent window
    /// lets `export` do the writing and then ends at a normal prompt.
    public static func setupScript(directory: String, intent: Intent) -> String {
        let binary = shellQuoted("\(directory)/\(CLICompanion.binaryName)")
        switch intent {
        case .thisSessionOnly:
            // A checkout has no bundle to export, so it gets the same temporary entry the
            // bundle's `--print` would have produced.
            let apply = isBundle(directory)
                ? "eval \"$(\(binary) export --print)\""
                : "export PATH=\"$PATH:\(doubleQuoted(directory))\""
            return (apply + "; " + interactiveShellStart).trimmingCharacters(in: .whitespaces)
        case .permanently:
            let export = isBundle(directory)
                ? "eval \"$(\(binary) export)\""
                : "export PATH=\"$PATH:\(doubleQuoted(directory))\""
            return "\(export); echo; \(binary) --help"
        }
    }

    /// Start the user's interactive shell, so a window running a one-shot script stays open.
    ///
    /// `exec` replaces the script's shell instead of nesting one, and `-i` keeps it
    /// interactive; `$SHELL` is inherited from Terminal, so this follows the user's own shell
    /// rather than assuming zsh.
    static var interactiveShellStart: String {
        "exec \"${SHELL:-/bin/zsh}\" -i"
    }

    /// True when `directory` is inside an `.app` bundle, which is what makes `export` and
    /// `export --print` available.
    static func isBundle(_ directory: String) -> Bool {
        directory.contains(".app/Contents/")
    }

    /// Start Terminal running `script`, in a new window.
    ///
    /// The Apple event is sent after the current SwiftUI action returns: AppleScript needs a
    /// running main run loop, and calling it while SwiftUI is still unwinding a button press
    /// fails even though the same script succeeds on its own. Two ways of sending it, because
    /// `NSAppleScript` can fail from inside a sandboxed or ad-hoc-signed app with "not
    /// authorized to send Apple events"; `osascript` is the same Apple event under a system
    /// binary, which the user's own Terminal preference already covers.
    public static func open(script: String, completion: @escaping (Result<Void, LaunchError>) -> Void) {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            let result = startInProcess(script: script)
            if case .failure = result {
                log.error("NSAppleScript failed, falling back to osascript: \(String(describing: result))")
                startWithOsascript(script: script, completion: completion)
            } else {
                completion(result)
            }
        }
        #else
        completion(.failure(.terminalUnavailable))
        #endif
    }

    /// AppleScript source that opens a new window and runs `script` in it.
    ///
    /// A window is opened explicitly: `do script` without `in window` lands in the window the
    /// user is already looking at, which would replace their session.
    static func appleScriptSource(script: String) -> String {
        """
        tell application "Terminal"
            do script "\(appleScriptString(script))"
            activate
        end tell
        """
    }

    private static func startInProcess(script: String) -> Result<Void, LaunchError> {
        #if canImport(AppKit)
        var error: NSDictionary?
        let executed = NSAppleScript(source: appleScriptSource(script: script))?
            .executeAndReturnError(&error)
        if let executed, error == nil, executed.descriptorType != 0 {
            return .success(())
        }
        guard let error else { return .failure(.terminalUnavailable) }
        return .failure(.appleScriptFailed(
            number: error[NSAppleScript.errorNumber] as? Int ?? -1,
            message: error[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
        ))
        #else
        return .failure(.terminalUnavailable)
        #endif
    }

    /// Run `osascript` off the main thread and report when it exits.
    private static func startWithOsascript(script: String, completion: @escaping (Result<Void, LaunchError>) -> Void) {
        #if canImport(AppKit)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScriptSource(script: script)]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice

            let result: Result<Void, LaunchError>
            do {
                try process.run()
                process.waitUntilExit()
                let message = String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    result = .success(())
                } else {
                    log.error("osascript failed (\(process.terminationStatus)): \(message)")
                    result = .failure(.appleScriptFailed(number: Int(process.terminationStatus), message: message))
                }
            } catch {
                result = .failure(.terminalUnavailable)
            }
            DispatchQueue.main.async { completion(result) }
        }
        #else
        completion(.failure(.terminalUnavailable))
        #endif
    }

    /// Quote a string as an AppleScript literal. Backslash and `"` are the whole language.
    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func doubleQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
