import Foundation
import ProxyMaxxPluginSDK

/// Integration fixture plugin: a real executable built on ProxyMaxxPluginSDK,
/// spawned by PluginRunner in SDKIntegrationTests. Speaks Protocol v1 over
/// stdin/stdout through the SDK's JSONLinesBridge.
///
/// argv: [0] executable, [1] result file path, [2] scenario mode.
/// Writes one `KEY=value` line to the result file; the test polls for it.

func write(result: String, to path: String) {
    FileHandle.standardError.write(Data("[SDKFixture] writing: \(result)\n".utf8))
    let payload = Data((result + "\n").utf8)
    try? payload.write(to: URL(fileURLWithPath: path))
}

func wire(_ status: PermissionStatus) -> String { status.wireString }

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { exit(2) }
let resultFile = arguments[1]
let mode = arguments[2]

do {
    let permissions = try PermissionManager()

    switch mode {
    case "request":
        let status = try await permissions.request("local-map.create")
        write(result: "REQUEST=\(wire(status))", to: resultFile)

    case "requestTwice":
        // Second request must not re-prompt for a denied permission.
        let first = try await permissions.request("local-map.create")
        let second = try await permissions.request("local-map.create")
        write(result: "REQUEST=\(wire(first)) \(wire(second))", to: resultFile)

    case "check":
        let status = try await permissions.check("local-map.create")
        write(result: "CHECK=\(wire(status))", to: resultFile)

    case "checkAll":
        let statuses = try await permissions.checkAll()
        let rendered = statuses.keys.sorted()
            .map { "\($0)=\(wire(statuses[$0]!))" }
            .joined(separator: " ")
        write(result: "CHECKALL=\(rendered)", to: resultFile)

    case "requestAll":
        let statuses = try await permissions.requestAll(["local-map.read", "local-map.create"])
        let rendered = ["local-map.read", "local-map.create"]
            .map { "\($0)=\(wire(statuses[$0]!))" }
            .joined(separator: " ")
        write(result: "REQUESTALL=\(rendered)", to: resultFile)

    case "cancel":
        let task = Task { try await permissions.request("local-map.create") }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            let status = try await task.value
            write(result: "CANCEL=\(wire(status))", to: resultFile)
        } catch is CancellationError {
            write(result: "CANCEL=CANCELLED", to: resultFile)
        } catch {
            write(result: "CANCEL=ERROR:\(error)", to: resultFile)
        }

    case "undeclared":
        do {
            _ = try await permissions.request("filesystem.read")
            write(result: "UNDECLARED=UNEXPECTED-GRANT", to: resultFile)
        } catch PermissionError.notDeclared(let id) {
            write(result: "UNDECLARED=NOT-DECLARED:\(id)", to: resultFile)
        }

    default:
        write(result: "UNKNOWN-MODE=\(mode)", to: resultFile)
        exit(2)
    }
} catch is CancellationError {
    write(result: "CANCELLED", to: resultFile)
} catch PermissionError.hostUnavailable {
    write(result: "HOST-UNAVAILABLE", to: resultFile)
} catch {
    write(result: "ERROR:\(error)", to: resultFile)
}
