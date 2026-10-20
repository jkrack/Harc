import Foundation
import Testing
@testable import HarcDomain

@Suite("Host speaker processing outcome")
struct HostSpeakerProcessingOutcomeTests {
    private func outcome(_ clusters: [HostSpeakerProcessingOutcome.Cluster],
        diarization: HostSpeakerProcessingOutcome.Diarization = .completed,
        digest: Data = Data(repeating: 3, count: 32)) throws -> HostSpeakerProcessingOutcome {
        try HostSpeakerProcessingOutcome(canonicalRecordingID: .random(),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)),
            producerDeviceID: DeviceID(Data(repeating: 2, count: 32)),
            processingArtifactSHA256: digest, diarization: diarization, clusters: clusters)
    }

    @Test func completedWorkPreservesMissingEvidenceAndDisabledIsSeparate() throws {
        let missing = try HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0)
        let evaluated = try HostSpeakerProcessingOutcome.Cluster(speakerIndex: 1,
            evidenceSHA256: Data(repeating: 4, count: 32), decisionOperationID: .random(), disposition: .noMatch, recognitionPackRevision: EntityRevision(1))
        let value = try outcome([evaluated, missing])
        #expect(value.clusters.map(\.speakerIndex) == [0, 1])
        #expect(value.clusters[0].decisionOperationID == nil)
        #expect(try JSONDecoder().decode(HostSpeakerProcessingOutcome.self,
            from: JSONEncoder().encode(value)) == value)
        #expect(try outcome([], diarization: .disabled).diarization == .disabled)
        #expect(throws: (any Error).self) { try outcome([missing], diarization: .disabled) }
    }

    @Test func malformedAndDuplicateCompletionClaimsFailIncludingDecode() throws {
        let op = OperationID.random()
        let digest = Data(repeating: 4, count: 32)
        let cluster = try HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0,
            evidenceSHA256: digest, decisionOperationID: op, disposition: .noMatch, recognitionPackRevision: EntityRevision(1))
        #expect(throws: (any Error).self) { try outcome([cluster, cluster]) }
        #expect(throws: (any Error).self) {
            try outcome([cluster, HostSpeakerProcessingOutcome.Cluster(speakerIndex: 1,
                evidenceSHA256: digest, decisionOperationID: op, disposition: .noMatch, recognitionPackRevision: EntityRevision(1))])
        }
        #expect(throws: (any Error).self) { try outcome([], digest: Data()) }
        for bytes in [Data(), Data(repeating: 1, count: 31), Data(repeating: 1, count: 33)] {
            #expect(throws: (any Error).self) {
                try HostSpeakerProcessingOutcome.Cluster(speakerIndex: 0,
                    evidenceSHA256: bytes, decisionOperationID: op, disposition: .noMatch, recognitionPackRevision: EntityRevision(1))
            }
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome([cluster]))) as? [String: Any])
        var rows = try #require(json["clusters"] as? [[String: Any]])
        rows[0].removeValue(forKey: "decisionOperationID")
        json["clusters"] = rows
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HostSpeakerProcessingOutcome.self,
                from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
