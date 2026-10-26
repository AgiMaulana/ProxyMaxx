import Foundation
import FlowKit

/// Resolves once per accepted connection, with libproc and AppKit work off the event loop.
public final class ClientAppResolver: ClientAppResolving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "oss.proxymaxx.clientkit.resolver", qos: .utility)
    private let probe: any SocketOwnershipProbing

    public convenience init() {
        self.init(probe: ClientSocketScanner())
    }

    init(probe: any SocketOwnershipProbing) {
        self.probe = probe
    }

    public func resolveClientApp(
        clientAddress: String,
        clientPort: Int,
        proxyAddress: String,
        proxyPort: Int,
        completion: @escaping @Sendable (ClientApp?) -> Void
    ) {
        queue.async { [self] in
            guard let pid = probe.pid(
                clientAddress: clientAddress, clientPort: clientPort,
                proxyAddress: proxyAddress, proxyPort: proxyPort
            ) else {
                completion(nil)
                return
            }
            completion(ClientIdentity.client(for: pid))
        }
    }
}
