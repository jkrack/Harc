import Foundation
@testable import HarcClientTransport
import Testing

@Suite("Transport error diagnostics")
struct HarcTransportErrorDiagnosticTests {
    private enum FixtureError: Error {
        case disconnected
    }

    private enum LocalizedFixtureError: LocalizedError {
        case hostOffline

        var errorDescription: String? {
            "The adopted Host is offline."
        }
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

    @Test("generic localized errors use their product message")
    func localizedGenericError() {
        let diagnostic = HarcTransportErrorDiagnostic.describe(
            LocalizedFixtureError.hostOffline
        )

        #expect(diagnostic.type.contains("LocalizedFixtureError"))
        #expect(diagnostic.summary == "The adopted Host is offline.")
        #expect(diagnostic.rpcCode == nil)
    }
}
