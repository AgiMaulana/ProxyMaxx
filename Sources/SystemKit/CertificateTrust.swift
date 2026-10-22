import Foundation

/// Installs and removes the proxy's root certificate in the **user** trust domain.
///
/// The admin trust domain is governed by the `com.apple.trust-settings.admin`
/// authorization rule, whose value is `entitled, authenticate-admin`: it requires either
/// an Apple-private entitlement or an *interactive* administrator authentication. A root
/// daemon can therefore never satisfy it — that is why a privileged helper is useless
/// here, and why `security` run from one reports "no user interaction was possible".
///
/// The user domain is governed by `entitled-session-owner-or-authenticate-session-owner`,
/// which the logged-in owner satisfies on their own behalf. No administrator rights, no
/// password, and in practice no prompt at all.
public enum CertificateTrust {
    /// True when the certificate is currently **trusted** for this user.
    ///
    /// Reads the trust settings rather than keychain membership: a certificate can sit in a
    /// keychain without being trusted, which is exactly what a failed install leaves
    /// behind, and reporting that as "installed" is misleading.
    public static func isInstalled(commonName: String) -> Bool {
        guard !commonName.isEmpty else { return false }
        let dump = try? Shell.run(Shell.security, ["dump-trust-settings"])
        return dump?.succeeded == true && dump?.output.contains(commonName) == true
    }

    /// Trust `certificateDER` for the current user. No administrator rights, no prompt.
    ///
    /// Mirrors the command ProxyMaxx itself runs, including the explicit `-k` pointing at
    /// the user's default keychain. The one deliberate difference is the `-p ssl -p basic`
    /// scoping: ProxyMaxx trusts the root for every policy, which grants more than a
    /// debugging proxy needs.
    public static func install(certificateDER: Data, commonName: String) throws {
        let certificateURL = try stage(certificateDER)
        defer { try? FileManager.default.removeItem(at: certificateURL) }

        // Drop any previous copy so a re-install replaces rather than duplicates.
        removeStoredCertificates(commonName: commonName)

        guard let keychain = Shell.userDefaultKeychainPath() else {
            throw ShellError.commandFailed(tool: "security", status: -1, message: "could not locate the user keychain")
        }

        let result = try Shell.run(Shell.security, [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-p", "basic",
            "-k", keychain, certificateURL.path,
        ])
        guard result.succeeded else {
            let detail = result.error.isEmpty ? result.output : result.error
            throw ShellError.commandFailed(tool: "security", status: result.status, message: detail)
        }
    }

    /// Remove the trusted root certificate from the user's trust settings and keychain.
    public static func uninstall(certificateDER: Data, commonName: String) throws {
        let certificateURL = try stage(certificateDER)
        defer { try? FileManager.default.removeItem(at: certificateURL) }

        // Drop the trust rule first, then every stored copy of the certificate.
        _ = try? Shell.run(Shell.security, ["remove-trusted-cert", certificateURL.path])
        removeStoredCertificates(commonName: commonName)
    }

    /// Delete every copy of the certificate held in the user's keychain, keyed by SHA-1 —
    /// the same technique ProxyMaxx uses, which also clears duplicates from earlier installs.
    ///
    /// Done by listing the hashes and deleting each one, rather than piping through
    /// `awk`/`sh` as ProxyMaxx does: no shell means the common name cannot alter a command.
    @discardableResult
    private static func removeStoredCertificates(commonName: String) -> [ShellResult] {
        guard !commonName.isEmpty, let keychain = Shell.userDefaultKeychainPath() else { return [] }
        guard let listing = try? Shell.run(Shell.security, ["find-certificate", "-c", commonName, "-a", "-Z", keychain]),
              listing.succeeded else {
            return []
        }

        let hashes = listing.output
            .split(separator: "\n")
            .filter { $0.hasPrefix("SHA-1 hash:") }
            .map { $0.replacingOccurrences(of: "SHA-1 hash:", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return hashes.compactMap { hash in
            try? Shell.run(Shell.security, ["delete-certificate", "-Z", hash, keychain])
        }
    }

    private static func stage(_ der: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxymaxx-ca-\(UUID().uuidString).cer")
        try der.write(to: url, options: .atomic)
        return url
    }
}
