import Foundation
import Testing
import HarcCore

@Suite("Speaker embedding provenance")
struct SpeakerEmbeddingProvenanceTests {
    @Test func legacyPayloadRetainsWeSpeakerIdentity() throws {
        let data = Data(#"{"speakerIndex":0,"vector":[0.5,0.5],"totalMs":3000,"segmentCount":1}"#.utf8)
        let row = try JSONDecoder().decode(SpeakerEmbeddingRow.self, from: data)
        #expect(row.modelID == "wespeaker_v2")
    }
    @Test func explicitIdentitySurvivesSerialization() throws {
        let row = SpeakerEmbeddingRow(speakerIndex: 2, vector: [0.5,0.5], totalMs: 3000,
                                      segmentCount: 1, modelID: "diagnostic-ecapa-revision")
        let data = try JSONEncoder().encode(row)
        #expect(try JSONDecoder().decode(SpeakerEmbeddingRow.self, from: data) == row)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["modelID"] as? String == row.modelID)
    }
    @Test(arguments: ["null", "12", #""""#, #""   ""#])
    func explicitInvalidIdentityDoesNotBecomeLegacy(_ value: String) {
        let data = Data("{\"speakerIndex\":0,\"vector\":[0.5],\"totalMs\":3000,\"segmentCount\":1,\"modelID\":\(value)}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SpeakerEmbeddingRow.self, from: data) }
    }
    @Test func existingInitializerRemainsLegacyProducer() {
        let row = SpeakerEmbeddingRow(speakerIndex: 0, vector: [1], totalMs: 3000, segmentCount: 1)
        #expect(row.modelID == "wespeaker_v2")
    }
}
