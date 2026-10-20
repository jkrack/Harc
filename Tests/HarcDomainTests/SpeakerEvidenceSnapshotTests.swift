import Foundation
import Testing
@testable import HarcDomain

@Suite("Immutable speaker evidence")
struct SpeakerEvidenceSnapshotTests {
    private func fixture() throws -> SpeakerEvidenceSnapshot {
        try SpeakerEvidenceSnapshot(
            canonicalRecordingID: CanonicalRecordingID(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)),
            producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterID: "cluster-0",
            embedding: QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127, 0, 255]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 2)
    }

    private func modified(_ edit: (inout [String: Any]) -> Void) throws -> SpeakerEvidenceSnapshot {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        edit(&json)
        return try JSONDecoder().decode(SpeakerEvidenceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func stableIdentitySurvivesSerialization() throws {
        let value = try fixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoded = try JSONDecoder().decode(SpeakerEvidenceSnapshot.self, from: encoder.encode(value))
        #expect(decoded == value)
        #expect(decoded.evidenceSHA256 == value.evidenceSHA256)
        #expect(value.evidenceSHA256.map { String(format: "%02x", $0) }.joined() == "cd18e4b3759020d74e6406a4c35c4dcee5065f4288472d136bccafe237cf2c5c")
    }

    @Test func everyAuthorityAndPayloadFieldChangesIdentity() throws {
        let original = try fixture().evidenceSHA256
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["canonicalRecordingID"] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" },
            { $0["canonicalPCMHash"] = Data(repeating: 4, count: 32).base64EncodedString() },
            { $0["producerDeviceID"] = Data(repeating: 4, count: 32).base64EncodedString() },
            { $0["processingArtifactSHA256"] = Data(repeating: 4, count: 32).base64EncodedString() },
            { $0["localClusterID"] = "cluster-1" },
            { $0["modelID"] = "wespeaker_v3" },
            { $0["speechDurationMs"] = 6001 },
            { $0["segmentCount"] = 3 },
            { var e = $0["embedding"] as! [String: Any]; e["scale"] = 0.25; $0["embedding"] = e },
            { var e = $0["embedding"] as! [String: Any]; e["values"] = Data([0, 127, 255]).base64EncodedString(); $0["embedding"] = e },
            { var e = $0["embedding"] as! [String: Any]; e["dimensions"] = 4; e["values"] = Data([127, 0, 255, 1]).base64EncodedString(); $0["embedding"] = e }
        ]
        let identities = try edits.map { try modified($0).evidenceSHA256 }
        #expect(identities.allSatisfy { $0 != original })
        #expect(Set(identities).count == edits.count)
    }

    @Test func persistedInputCannotBypassValidation() throws {
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["processingArtifactSHA256"] = Data([1]).base64EncodedString() },
            { $0["localClusterID"] = "" },
            { $0["localClusterID"] = " cluster-0" },
            { $0["localClusterID"] = "a\u{0}b" },
            { $0["localClusterID"] = "e\u{301}" },
            { $0["modelID"] = String(repeating: "x", count: 129) },
            { $0["speechDurationMs"] = 0 },
            { $0["segmentCount"] = 0 },
            { var e = $0["embedding"] as! [String: Any]; e["dimensions"] = 4; $0["embedding"] = e },
            { var e = $0["embedding"] as! [String: Any]; e["scale"] = 0; $0["embedding"] = e },
            { var e = $0["embedding"] as! [String: Any]; e["values"] = Data([0, 0, 0]).base64EncodedString(); $0["embedding"] = e }
        ]
        for edit in edits { #expect(throws: (any Error).self) { try modified(edit) } }
    }
}
