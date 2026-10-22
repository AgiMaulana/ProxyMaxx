import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String

    public var succeeded: Bool { status == 0 }
}

public enum ShellError: Error, CustomStringConvertible {
    case commandFailed(tool: String, status: Int32, message: String)
    case userCancelled

    public var description: String {
        switch self {
        case .commandFailed(let tool, let status, let message):
            return "\(tool) failed (exit \(status)): \(message)"
        case .userCancelled:
            return "Administrator privileges were not granted"
        }
    }
}

enum Shell {
    static let networksetup = "/usr/sbin/networksetup"
    static let security = "/usr/bin/security"

    /// Path of the user's default keychain (`security default-keychain -d user`).
    ///
    /// ProxyMaxx installs its root certificate here, which is what keeps the whole operation
    /// inside the user trust domain and therefore free of administrator prompts.
    static func userDefaultKeychainPath() -> String? {
        guard let result = try? run(security, ["default-keychain", "-d", "user"]), result.succeeded else {
            return nil
        }
        return result.output.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\""))
    }

    /// Run a launchable tool and capture its output.
    ///
    /// `stdin` is written and closed before the output is read, so a script that asks a
    /// question on standard input gets an answer rather than an immediate end of file.
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], stdin: String? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var input: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
        }

        try process.run()
        if let inputPipe = input, let inputText = stdin {
            inputPipe.fileHandleForWriting.write(Data(inputText.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Run a shell script as root, prompting the user for authorisation.
    ///
    /// The script is written to a private temporary file so nothing has to be escaped
    /// through AppleScript; the temporary file is removed afterwards.
    @discardableResult
    static func runPrivileged(script: String) throws -> ShellResult {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxymaxx-admin-\(UUID().uuidString).sh")
        let wrapped = "#!/bin/sh\nset -e\n\(script)\n"
        try wrapped.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        return try runPrivilegedScript(at: scriptURL)
    }

    /// Run an existing script file as root, prompting the user once.
    @discardableResult
    static func runPrivilegedScript(at scriptURL: URL) throws -> ShellResult {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let escapedPath = scriptURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"/bin/sh \\\"\(escapedPath)\\\"\" with administrator privileges"
        let result = try run("/usr/bin/osascript", ["-e", appleScript])

        if result.status != 0, result.error.contains("-128") {
            throw ShellError.userCancelled
        }
        guard result.status == 0 else {
            throw ShellError.commandFailed(tool: "osascript", status: result.status, message: result.error)
        }
        return result
    }
}
