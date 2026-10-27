import Foundation
import FlowKit

/// Resolves once per accepted connection, with libproc and AppKit work off the event loop.
///
/// Concurrent: browsers open many connections at once and each scan walks every
/// process, so serializing lookups stalls every connection behind the first.
public final class ClientAppResolver: ClientAppResolving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "oss.proxymaxx.clientkit.resolver", qos: .utility, attributes: .concurrent)
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
