import Foundation
import FlowKit

/// Runtime configuration for the proxy engine.
public struct ProxyConfiguration: Sendable {
    /// Interface to bind. Defaults to loopback so only this machine can use it.
    public var host: String
    /// Port to listen on. 9090 matches ProxyMaxx's default.
    public var port: Int
    /// Port for the SOCKS5 listener, or nil to serve HTTP only.
    ///
    /// Android clients reach the proxy through SOCKS5 rather than the system proxy — see
    /// `SOCKS5Handler` — so the tunnel app needs this. 8989 matches ProxyMaxx's default.
    public var socksPort: Int?
    /// Whether to validate upstream server certificates. Debugging proxies
    /// typically accept invalid upstream certificates; TLS to the client is
    /// always performed with a locally-trusted leaf.
    public var verifyUpstreamCertificates: Bool
    /// Requests with bodies larger than this are rejected.
    public var maxRequestBodyBytes: Int
    /// Time allowed to establish an upstream connection.
    public var connectTimeoutSeconds: Int
    /// Time allowed for an upstream response to complete.
    public var requestTimeoutSeconds: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 9090,
        socksPort: Int? = 8989,
        verifyUpstreamCertificates: Bool = false,
        maxRequestBodyBytes: Int = 64 * 1024 * 1024,
        connectTimeoutSeconds: Int = 15,
        requestTimeoutSeconds: Int = 120
    ) {
        self.host = host
        self.port = port
        self.socksPort = socksPort
        self.verifyUpstreamCertificates = verifyUpstreamCertificates
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
}

public enum ProxyKitError: Error, CustomStringConvertible {
    case tlsSetup(String)
    case malformedRequest(String)
    case upstreamConnect(String)
    case requestTooLarge(Int)

    public var description: String {
        switch self {
        case .tlsSetup(let detail): return "TLS setup failed: \(detail)"
        case .malformedRequest(let detail): return "Malformed request: \(detail)"
        case .upstreamConnect(let detail): return "Upstream connection failed: \(detail)"
        case .requestTooLarge(let limit): return "Request body exceeds the \(limit) byte limit"
        }
    }
}

/// Signals emitted by the engine as flows progress.
public enum ProxyEvent: Sendable {
    /// A flow was created, updated, completed, or failed. Upsert by `Flow.id`.
    case flow(Flow)
    /// The engine started or stopped listening.
    case stateChanged(isRunning: Bool, port: Int)
    /// A non-fatal engine-level diagnostic.
    case diagnostic(String)
}
