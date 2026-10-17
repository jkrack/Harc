import Foundation
import Testing
@testable import HarcDomain

@Suite("Artifact-scoped speaker cluster projection")
struct SpeakerClusterMapTests {
    private func evidence(cluster: String = "speaker-9", artifact: UInt8 = 3,
                          producer: UInt8 = 2, pcm: UInt8 = 1,
                          recording: CanonicalRecordingID? = nil) throws -> SpeakerEvidenceSnapshot {
        try SpeakerEvidenceSnapshot(canonicalRecordingID: recording ?? CanonicalRecordingID(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: pcm, count: 32)),
            producerDeviceID: DeviceID(Data(repeating: producer, count: 32)),
            processingArtifactSHA256: Data(repeating: artifact, count: 32), localClusterID: cluster,
            embedding: QuantizedSpeakerEmbedding(dimensions: 2, values: Data([127,0]), scale: 0.5),
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
    }
    private func mapping(_ clusters: [String]) throws -> SpeakerClusterMap {
        let value = try evidence()
        return try SpeakerClusterMap(canonicalRecordingID: value.canonicalRecordingID,
            canonicalPCMHash: value.canonicalPCMHash, producerDeviceID: value.producerDeviceID,
            processingArtifactSHA256: value.processingArtifactSHA256, localClusterIDs: clusters)
    }
    @Test func opaqueClusterMappingIsStableAndArtifactBound() throws {
        #expect(try mapping(["speaker with space"]).localClusterIDs == ["speaker with space"])
        let first = try mapping(["speaker-9", "speaker-2"])
        let reordered = try mapping(["speaker-2", "speaker-9"])
        #expect(first == reordered)
        #expect(first.mappingSHA256 == reordered.mappingSHA256)
        #expect(try first.canonicalSpeakerIndex(for: evidence()) == 1)
        #expect(try first.canonicalSpeakerIndex(for: evidence(cluster: "speaker-2")) == 0)
        #expect(try mapping(["speaker-9"]).mappingSHA256 != first.mappingSHA256)
        for value in [try evidence(artifact: 4), try evidence(producer: 4), try evidence(pcm: 4),
                      try evidence(recording: .random()), try evidence(cluster: "speaker-0")] {
            #expect(throws: (any Error).self) { try first.canonicalSpeakerIndex(for: value) }
        }
        let decoded = try JSONDecoder().decode(SpeakerClusterMap.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
        #expect(decoded.mappingSHA256 == first.mappingSHA256)
    }
    @Test func invalidAndDuplicateClustersRejectIncludingDuringDecode() throws {
        for clusters in [["same", "same"], [""], [" spaced"], ["line\nfeed"], ["é"], [String(repeating: "a", count: 129)]] {
            #expect(throws: (any Error).self) { try mapping(clusters) }
        }
        let value = try mapping(["speaker-9"])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["localClusterIDs"] = ["duplicate", "duplicate"]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SpeakerClusterMap.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
