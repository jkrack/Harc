import Testing
@testable import HarcProtocol

@Suite("HarcProtocol target wiring")
struct ProtocolTargetSmokeTests {
    @Test("the current protocol version is v1.0")
    func currentVersion() {
        #expect(HarcProtocolVersion.v1.major == 1)
        #expect(HarcProtocolVersion.v1.minor == 0)
    }
}
