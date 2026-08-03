#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
import HarcHostTransport
import NIOCore
import Testing

@Suite("Host transport API feasibility")
struct HostTransportAPIFeasibilityTests {
    @Test("A process-owned NWListener factory satisfies gRPC's custom transport")
    func customListenerFactoryBoundary() {
        let factory = HarcGRPCNWListenerFactory {
            throw StubError.listenerMustNotStartInCompileTest
        }

        let transport = HTTP2ServerTransport.Custom(listenerFactory: factory)
        #expect(type(of: transport) == HTTP2ServerTransport.Custom<HarcGRPCNWListenerFactory>.self)
    }

    @Test("The two listeners have disjoint ALPN profiles")
    func alpnProfiles() {
        #expect(HarcTLSListenerProtocol.grpcHTTP2.rawValue == "h2")
        #expect(HarcHTTP11UploadTransportAPI.requiredALPN == "http/1.1")
        #expect(Set(HarcTLSListenerProtocol.allCases.map(\.rawValue)).count == 2)
    }

    @Test("TLS session resumption is disabled to exclude 0-RTT")
    func noEarlyDataPolicy() {
        #expect(!HarcNetworkTLS13Policy.sessionResumptionEnabled)
    }

    @Test("The server TLS policy requires a concrete Security identity")
    func serverIdentityBoundary() {
        _ = HarcNetworkTLS13Policy.serverOptions(identity:protocol:)
        _ = HarcNetworkTLS13Policy.serverParameters(identity:protocol:)
    }

    @Test("The HTTP/1.1 boundary imports NIO body conversion separately")
    func backgroundHTTPBodyConversion() {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeString("harc")

        let data = HarcHTTP11UploadTransportAPI.data(copyingReadableBytes: buffer)

        #expect(Array(data) == Array("harc".utf8))
    }

    private enum StubError: Error {
        case listenerMustNotStartInCompileTest
    }
}
#endif
