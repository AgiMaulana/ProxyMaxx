import Foundation
import SystemKit

/// `proxymaxx-cli export` — make the bundled tool callable from any terminal.
///
/// A child process cannot change the environment of the shell that launched it, so the
/// command writes a marked block to the shell profile, which every new terminal reads, and
/// tells the caller how to apply the same change to the terminal already open. It prints
/// nothing a shell could mistake for a script: an earlier version printed an `export` line
/// on stdout, which looked pasteable but, applied by `eval`, compared its own literal text
/// against the directory and silently did nothing.
enum PathExportCommand {
    static func run(_ arguments: Arguments) throws {
        let shell = try resolveShell(arguments)
        let directory = executableDirectory()
        let profile = profileURL(arguments, shell: shell)

        if arguments.has("remove") {
            let removed = try ShellPathExport.remove(profileURL: profile)
            note(removed
                ? "removed the proxymaxx-cli PATH block from \(profile.path)"
                : "no proxymaxx-cli PATH block in \(profile.path)")
            return
        }

        if arguments.has("print") {
            // One line, for `eval "$(proxymaxx-cli export --print)"`: it affects only the
            // shell that evaluates it and writes nothing.
            print("\(ShellPathExport.exportLine(for: directory.path, shell: shell))")
            return
        }

        let installation = try ShellPathExport.install(
            directory: directory,
            shell: shell,
            profileURL: profile
        )
        if installation.changed {
            note("added \(directory.path) to PATH in \(installation.profileURL.path)")
        } else {
            note("\(directory.path) is already on PATH via \(installation.profileURL.path)")
        }
        note("open a new terminal, or apply it to this one with: source \(installation.profileURL.path)")
        note("one-off alternative: eval \"$(\(quotedExecutable) export --print)\"")
    }

    /// Decide which shell's profile to edit and which account it belongs to.
    private static func resolveShell(_ arguments: Arguments) throws -> ShellPathExport.Shell {
        guard let raw = arguments.value("shell"), !raw.isEmpty else {
            return ShellPathExport.detectShell()
        }
        guard let shell = ShellPathExport.Shell(rawValue: raw.lowercased()) else {
            throw CLIError("--shell must be zsh, bash or fish, got '\(raw)'")
        }
        return shell
    }

    private static func profileURL(_ arguments: Arguments, shell: ShellPathExport.Shell) -> URL {
        guard let path = arguments.value("profile"), !path.isEmpty else {
            return ShellPathExport.profileURL(for: shell)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The folder holding the binary that is running, with symlinks resolved so a linked
    /// copy still exports the real bundle rather than a `~/.local/bin` alias.
    static func executableDirectory() -> URL {
        resolveExecutable().deletingLastPathComponent()
    }

    static func resolveExecutable() -> URL {
        let raw = CommandLine.arguments.first ?? ShellPathExport.Shell.zsh.rawValue
        if raw.contains("/") {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(raw)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return URL(fileURLWithPath: raw)
    }

    /// The command a user can paste to re-apply the line in the current shell. Quoted so a
    /// bundle under `~/Applications/My Apps` still copies cleanly.
    private static var quotedExecutable: String {
        ShellPathExport.shellQuoted(resolveExecutable().path, shell: ShellPathExport.detectShell())
    }
}
