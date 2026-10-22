import Foundation
import CertKit
import SystemKit

/// Certificate commands. Trust changes go through the same `CertificateTrust` helper the
/// app uses: the user trust domain allows the session owner to install without admin
/// rights, so an agent approving it once is all it takes.
enum CertCommand {
    static func run(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError("cert needs an action (status|install|uninstall|export)")
        }
        let body = arguments.after(action)
        let authority = try CertificateStorage.loadOrCreate()

        switch action {
        case "status":
            let trusted = CertificateTrust.isInstalled(commonName: authority.commonName)
            print("""
            {
              "commonName": "\(authority.commonName)",
              "trusted": \(trusted),
              "certFile": "\(CertificateStorage.defaultDirectory.appendingPathComponent(CertificateStorage.certificateFileName).path)"
            }
            """)
        case "install":
            try CertificateTrust.install(certificateDER: authority.certificateDER, commonName: authority.commonName)
            note("root CA installed and trusted for user domain (\(authority.commonName))")
        case "uninstall":
            try CertificateTrust.uninstall(certificateDER: authority.certificateDER, commonName: authority.commonName)
            note("root CA trust removed (\(authority.commonName))")
        case "export":
            guard let path = body.value("out") else {
                throw CLIError("cert export needs --out PATH", hint: "proxymaxx-cli cert export --out ~/Desktop/ca.cer")
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if body.has("pem") {
                try CertificateStorage.exportPEM(authority, to: url)
            } else {
                try CertificateStorage.exportDER(authority, to: url)
            }
            note("exported \(body.has("pem") ? "PEM" : "DER") to \(url.path)")
        default:
            throw CLIError("unknown cert action '\(action)'", hint: "status|install|uninstall|export")
        }
    }
}
