@testable import HarcClientTransport
import Testing

@Suite("Transport error diagnostics")
struct HarcTransportErrorDiagnosticTests {
    private enum FixtureError: Error {
        case disconnected
    }

    @Test("generic errors retain their concrete type without inventing an RPC code")
    func genericError() {
        let diagnostic = HarcTransportErrorDiagnostic.describe(
            FixtureError.disconnected
        )

        #expect(diagnostic.type.contains("FixtureError"))
        #expect(diagnostic.summary == "disconnected")
        #expect(diagnostic.rpcCode == nil)
        #expect(diagnostic.rpcCodeNumber == nil)
        #expect(diagnostic.rpcMessage == nil)
        #expect(diagnostic.cause == nil)
    }
}
