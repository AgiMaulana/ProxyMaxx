import Foundation

/// Adds the folder that contains `proxymaxx-cli` to the user's `PATH`.
///
/// A process cannot change the environment of the shell that launched it, so an install is
/// the marked block in the shell profile that every future terminal reads. The terminal
/// already open is brought along with `source` (or `eval "$(… export --print)"`), which the
/// CLI names when it is done. The block is rewritten rather than duplicated, so repeated
/// runs — a checkout, then `/Applications` — stay idempotent.
public enum ShellPathExport {
    public enum Shell: String, Sendable, CaseIterable {
        case zsh
        case bash
        case fish
    }

    /// Delimiters around the lines this tool owns. Everything between them is replaced on
    /// install and removed by `remove`, so a hand-edited block cannot accumulate.
    public static let markerBegin = "# >>> proxymaxx-cli >>>"
    public static let markerEnd = "# <<< proxymaxx-cli <<<"

    public struct Installation: Sendable {
        public let shell: Shell
        public let profileURL: URL
        public let directory: String
        public let exportLine: String
        /// False when the profile already contained exactly what this install would write.
        public let changed: Bool
    }

    /// The lines the profile block holds for `directory`: just the export.
    ///
    /// A second line that pruned an older copy of the same tool from `PATH` was tried and
    /// removed: zsh's `${PATH//…/…}` replacement also rewrites the `:x:` it matches in the
    /// middle of a neighbour entry, so a checkout followed by `/Applications` produced
    /// entries like `/a:/a/b` and took `tr` and `grep` with it. Which copy wins is settled by
    /// order instead — a newer export is appended later, and `PATH` resolves left to right —
    /// and `export --remove` clears a block the user no longer wants.
    public static func scriptLines(for directory: String, shell: Shell) -> [String] {
        [exportLine(for: directory, shell: shell)]
    }

    /// The shell whose profile should be edited, from `$SHELL`.
    ///
    /// macOS defaults to zsh, so an unset or unrecognised `$SHELL` is treated as zsh rather
    /// than failing: writing the block is still more useful than refusing.
    public static func detectShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Shell {
        guard let path = environment["SHELL"], !path.isEmpty else { return .zsh }
        let name = (path as NSString).lastPathComponent
        return Shell(rawValue: name) ?? .zsh
    }

    /// The startup file a new interactive shell reads on macOS.
    public static func profileURL(
        for shell: Shell,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        switch shell {
        case .zsh:
            return homeDirectory.appendingPathComponent(".zshrc")
        case .bash:
            return homeDirectory.appendingPathComponent(".bash_profile")
        case .fish:
            return homeDirectory.appendingPathComponent(".config/fish/config.fish")
        }
    }

    /// The statement a shell runs to prepend `directory` to `PATH`.
    ///
    /// The folder matters, not the binary: `PATH` holds directories, so a line ending in
    /// `…/proxymaxx-cli` would make the shell look for `…/proxymaxx-cli/proxymaxx-cli`.
    public static func exportLine(for directory: String, shell: Shell) -> String {
        switch shell {
        case .fish:
            return "set -gx PATH $PATH \(singleQuoted(directory))"
        case .zsh, .bash:
            return "export PATH=\"$PATH:\(doubleQuoted(directory))\""
        }
    }

    /// Quote `value` so a shell reads it as one literal word. Paths under
    /// `~/Applications/My Apps` are ordinary, and an unquoted one would split in two.
    public static func shellQuoted(_ value: String, shell: Shell) -> String {
        switch shell {
        case .fish:
            return singleQuoted(value)
        case .zsh, .bash:
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// Append or refresh the managed block in `profileURL`.
    public static func install(
        directory: URL,
        shell: Shell,
        profileURL: URL,
        fileManager: FileManager = .default
    ) throws -> Installation {
        let directoryPath = directory.path
        let lines = scriptLines(for: directoryPath, shell: shell)
        let target = profileURL.resolvingSymlinksInPath()
        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let stripped = removingManagedBlock(from: existing)

        // Someone may already have this exact line outside our block; adding a second copy
        // would make `PATH` grow on every new shell.
        let updated = stripped.contains(lines[0])
            ? existing
            : appendManagedBlock(lines: lines, to: stripped)

        let changed = updated != existing
        if changed {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try updated.write(to: target, atomically: true, encoding: .utf8)
        }

        return Installation(
            shell: shell,
            profileURL: target,
            directory: directoryPath,
            exportLine: lines[0],
            changed: changed
        )
    }

    /// Remove the managed block, leaving the rest of the profile untouched.
    @discardableResult
    public static func remove(
        profileURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let target = profileURL.resolvingSymlinksInPath()
        guard let existing = try? String(contentsOf: target, encoding: .utf8) else {
            return false
        }
        let updated = removingManagedBlock(from: existing)
        guard updated != existing else { return false }
        try updated.write(to: target, atomically: true, encoding: .utf8)
        return true
    }

    /// True when `directory` is already present as a `PATH` entry in the profile, whether
    /// this tool wrote it or not.
    public static func isConfigured(
        directory: String,
        shell: Shell,
        profileURL: URL
    ) -> Bool {
        guard let existing = try? String(contentsOf: profileURL.resolvingSymlinksInPath(), encoding: .utf8) else {
            return false
        }
        return existing.contains(exportLine(for: directory, shell: shell))
    }

    /// Restore the surroundings of a managed block that piling has left without a blank
    /// separator, without touching anything else in the profile.
    static func normalizingSurroundings(_ text: String) -> String {
        text.replacingOccurrences(of: "\n\n\(markerBegin)", with: "\n\(markerBegin)")
    }

    // MARK: - Block surgery

    static func removingManagedBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var inside = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == markerBegin {
                inside = true
                continue
            }
            if inside, trimmed == markerEnd {
                inside = false
                continue
            }
            if !inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    private static func appendManagedBlock(lines: [String], to text: String) -> String {
        let block = ([markerBegin] + lines + [markerEnd]).joined(separator: "\n")
        guard !text.isEmpty else { return block + "\n" }
        var base = text
        if !base.hasSuffix("\n") { base += "\n" }
        if !base.hasSuffix("\n\n") { base += "\n" }
        return base + block + "\n"
    }

    private static func doubleQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\", "\"", "$", "`":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
