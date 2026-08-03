#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
import NIOCore
import NIOSSL

/// The application trust verifier for Harc's authority-signed TLS transport
/// set. It receives the untrusted peer chain and must complete exactly once.
/// No system-trust or insecure fallback is applied around this decision.
public protocol HarcPeerCertificateVerifier: Sendable {
    func verify(
        peerCertificateChain: [NIOSSLCertificate],
        promise: EventLoopPromise<NIOSSLVerificationResult>
    )
}

public enum HarcPinnedGRPCTLSError: Error, Equatable {
    case emptyServerHostname
}

/// Compile-proven gRPC Swift 2 client configuration for Harc's pinned TLS
/// channel. TLS is supplied as a NIO handler through gRPC 2.9's
/// `customSecure` channel callback so the authority/SPKI verifier controls the
/// handshake rather than the public Web PKI.
public struct HarcPinnedGRPCTLS: Sendable {
    public static let applicationProtocols = ["h2"]

    public let serverHostname: String
    public let tlsConfiguration: TLSConfiguration
    public let transportSecurity: HTTP2ClientTransport.TransportServices.TransportSecurity
    public let transportConfig: HTTP2ClientTransport.TransportServices.Config

    public init(
        serverHostname: String,
        verifier: any HarcPeerCertificateVerifier
    ) throws {
        guard !serverHostname.isEmpty else {
            throw HarcPinnedGRPCTLSError.emptyServerHostname
        }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.minimumTLSVersion = .tlsv13
        tlsConfiguration.maximumTLSVersion = .tlsv13
        tlsConfiguration.certificateVerification = .noHostnameVerification
        tlsConfiguration.applicationProtocols = Self.applicationProtocols

        let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
        var transportConfig = HTTP2ClientTransport.TransportServices.Config.defaults
        transportConfig.channelDebuggingCallbacks.onCreateTCPConnection = { channel in
            channel.eventLoop.makeCompletedFuture {
                let tlsHandler = try NIOSSLClientHandler(
                    context: tlsContext,
                    serverHostname: serverHostname,
                    customVerificationCallback: { certificateChain, promise in
                        guard !certificateChain.isEmpty else {
                            promise.succeed(.failed)
                            return
                        }
                        verifier.verify(
                            peerCertificateChain: certificateChain,
                            promise: promise
                        )
                    }
                )
                try channel.pipeline.syncOperations.addHandler(
                    tlsHandler,
                    name: "harc-pinned-tls",
                    position: .first
                )
            }
        }

        self.serverHostname = serverHostname
        self.tlsConfiguration = tlsConfiguration
        self.transportSecurity = .customSecure
        self.transportConfig = transportConfig
    }

    public func makeTransport(
        target: any ResolvableTarget
    ) throws -> HTTP2ClientTransport.TransportServices {
        try HTTP2ClientTransport.TransportServices(
            target: target,
            transportSecurity: transportSecurity,
            config: transportConfig
        )
    }
}

#endif
