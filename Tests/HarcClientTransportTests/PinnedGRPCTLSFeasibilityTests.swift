#if canImport(Network)
import HarcClientTransport
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing

@Suite("Client pinned gRPC TLS feasibility")
struct PinnedGRPCTLSFeasibilityTests {
    @Test("The client policy is TLS 1.3 with h2 only")
    func exactTLSProfile() throws {
        let policy = try HarcPinnedGRPCTLS(
            serverHostname: "harc-host.local",
            verifier: RejectingVerifier()
        )

        #expect(policy.tlsConfiguration.minimumTLSVersion == .tlsv13)
        #expect(policy.tlsConfiguration.maximumTLSVersion == .tlsv13)
        #expect(policy.tlsConfiguration.applicationProtocols == ["h2"])
        #expect(policy.transportConfig.channelDebuggingCallbacks.onCreateTCPConnection != nil)
    }

    @Test("The customSecure callback installs the pinning TLS handler")
    func customSecureHandlerInjection() throws {
        let policy = try HarcPinnedGRPCTLS(
            serverHostname: "harc-host.local",
            verifier: RejectingVerifier()
        )
        let callback = try #require(
            policy.transportConfig.channelDebuggingCallbacks.onCreateTCPConnection
        )
        let channel = EmbeddedChannel()

        try callback(channel).wait()
        _ = try channel.pipeline.syncOperations.handler(type: NIOSSLHandler.self)

        try channel.close().wait()
    }

    @Test("An empty hostname is rejected before transport construction")
    func emptyHostnameRejected() {
        #expect(throws: HarcPinnedGRPCTLSError.emptyServerHostname) {
            try HarcPinnedGRPCTLS(serverHostname: "", verifier: RejectingVerifier())
        }
    }

    private struct RejectingVerifier: HarcPeerCertificateVerifier {
        func verify(
            peerCertificateChain _: [NIOSSLCertificate],
            promise: EventLoopPromise<NIOSSLVerificationResult>
        ) {
            promise.succeed(.failed)
        }
    }
}
#endif
