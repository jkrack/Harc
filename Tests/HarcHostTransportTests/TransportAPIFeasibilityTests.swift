#if canImport(Network)
import GRPCNIOTransportHTTP2TransportServices
import HarcHost
import HarcHostTransport
import NIOCore
import Network
import Testing

@Suite("Host transport API feasibility")
struct HostTransportAPIFeasibilityTests {
    @Test("A resident generation controller owns both one-shot listener factories")
    func generationControllerBoundary() {
        _ = HarcTransportGenerationController.init(
            controlPort:uploadPort:eventLoopGroup:driver:
        )
        _ = HarcGRPCNWListenerFactory.init(lease:port:eventLoopGroup:)
        _ = HarcHTTP11UploadTransportAPI.makeListener(lease:port:)
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

    @Test("The server TLS policy requires consumed listener material")
    func serverListenerMaterialBoundary() {
        _ = HarcNetworkTLS13Policy.serverOptions(material:protocol:)
        _ = HarcNetworkTLS13Policy.serverParameters(material:protocol:)
    }

    @Test("The HTTP/1.1 boundary imports NIO body conversion separately")
    func backgroundHTTPBodyConversion() {
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeString("harc")

        let data = HarcHTTP11UploadTransportAPI.data(copyingReadableBytes: buffer)

        #expect(Array(data) == Array("harc".utf8))
    }
}
#endif
