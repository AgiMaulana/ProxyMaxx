import Foundation
import SystemKit
import Branding

/// `proxymaxx-cli version` — prints the installed version of ProxyMaxx.
///
/// Supports:
/// - Bare `proxymaxx-cli version` (or `-v`, `--version`): e.g. `ProxyMaxx 0.7.0 (build 700)`
/// - `proxymaxx-cli version --short`: e.g. `0.7.0`
/// - `proxymaxx-cli version --json`: e.g.
///   `{"build":"700","bundlePath":"/Applications/ProxyMaxx.app","installed":true,"origin":"homebrew","version":"0.7.0"}`
enum VersionCommand {
    struct Report: Encodable {
        var version: String
        var build: String?
        var bundlePath: String?
        var installed: Bool
        var origin: String?
    }

    static func run(_ arguments: Arguments) {
        let info = InstalledVersion.info()

        if arguments.has("json") {
            let report = Report(
                version: info.version,
                build: info.build,
                bundlePath: info.bundleURL?.path,
                installed: info.isBundled,
                origin: info.origin?.rawValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(report), let string = String(data: data, encoding: .utf8) {
                print(string)
            } else {
                print("{}")
            }
            return
        }

        if arguments.has("short") {
            print(info.version)
            return
        }

        print(info.displayString)
    }
}
