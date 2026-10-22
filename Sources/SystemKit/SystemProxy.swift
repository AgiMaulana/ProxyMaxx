import Foundation

/// Reads and writes the macOS system HTTP/HTTPS proxy settings.
///
/// Changes are applied to every enabled network service and require administrator
/// privileges, which are requested through a single authorisation prompt.
public enum SystemProxy {
    /// Names of network services that are currently enabled.
    public static func networkServices() throws -> [String] {
        let result = try Shell.run(Shell.networksetup, ["-listallnetworkservices"])
        guard result.succeeded else {
            throw ShellError.commandFailed(tool: "networksetup", status: result.status, message: result.error)
        }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            .map { $0.hasPrefix("*") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
    }

    /// Currently configured web proxy for the first service that reports one.
    public static func currentWebProxy() throws -> (host: String, port: Int)? {
        for service in try networkServices() {
            let result = try Shell.run(Shell.networksetup, ["-getwebproxy", service])
            guard result.succeeded else { continue }
            var host: String?
            var port: Int?
            var enabled = false
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "Enabled": enabled = parts[1] == "Yes"
                case "Server": host = parts[1]
                case "Port": port = Int(parts[1])
                default: break
                }
            }
            if enabled, let host, let port, !host.isEmpty {
                return (host, port)
            }
        }
        return nil
    }

    /// Route HTTP and HTTPS through `host:port` on every enabled network service.
    ///
    /// `networksetup` writes these settings as the logged-in user, so no administrator
    /// rights are needed. A managed or otherwise locked-down configuration can still
    /// refuse, in which case we escalate to a single authorised prompt.
    public static func enable(host: String, port: Int) throws {
        let services = try networkServices()
        if apply(services: services, host: host, port: port, enable: true, privileged: false).isEmpty {
            return
        }
        _ = apply(services: services, host: host, port: port, enable: true, privileged: true)
    }

    /// Turn the HTTP and HTTPS system proxies off on every network service.
    public static func disable() throws {
        let services = try networkServices()
        if apply(services: services, host: host_, port: 0, enable: false, privileged: false).isEmpty {
            return
        }
        _ = apply(services: services, host: host_, port: 0, enable: false, privileged: true)
    }

    private static let host_ = "127.0.0.1"

    /// Apply the change to each service, returning the services that refused.
    @discardableResult
    private static func apply(
        services: [String],
        host: String,
        port: Int,
        enable: Bool,
        privileged: Bool
    ) -> [String] {
        var refused: [String] = []
        for service in services {
            let commands: [[String]] = enable
                ? [["-setwebproxy", service, host, "\(port)"], ["-setsecurewebproxy", service, host, "\(port)"]]
                : [["-setwebproxystate", service, "off"], ["-setsecurewebproxystate", service, "off"]]

            for arguments in commands {
                if privileged {
                    let quoted = arguments.map { "\"\($0)\"" }.joined(separator: " ")
                    if (try? Shell.runPrivileged(script: "\(Shell.networksetup) \(quoted)")) == nil {
                        refused.append(service)
                    }
                } else if (try? Shell.run(Shell.networksetup, arguments))?.succeeded != true {
                    refused.append(service)
                }
            }
        }
        return refused
    }

    /// True when the system proxy already points at `host:port`.
    public static func isEnabled(host: String, port: Int) -> Bool {
        guard let current = try? currentWebProxy() else { return false }
        return current.host == host && current.port == port
    }
}
