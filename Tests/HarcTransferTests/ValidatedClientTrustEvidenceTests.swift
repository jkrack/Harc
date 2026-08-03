import Foundation
import HarcTransfer
import Testing

@Suite("Validated client trust evidence projections")
struct ValidatedClientTrustEvidenceTests {
    @Test("client grant protocol decoding rejects an unsupported major")
    func protocolDecodeRejectsWrongMajor() throws {
        let bytes = Data(#"{"major":2,"minor":0}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClientGrantProtocolVersion.self, from: bytes)
        }

        let valid = try ClientGrantProtocolVersion(minor: 1)
        #expect(
            try JSONDecoder().decode(
                ClientGrantProtocolVersion.self,
                from: JSONEncoder().encode(valid)
            ) == valid
        )
    }
}
