import Foundation
import CryptoKit
import XCTest
import GRDB
import HarcDomain
@testable import HarcStore
@testable import HarcHost
import HarcIdentity

// The legacy remote endpoint must not treat client cluster indices as canonical indices.
final class UnmappedSpeakerBoundaryTests: XCTestCase {
    func test_remoteSlotCannotMisnameCanonicalVoiceOrEnrollUnmappedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let queue = await store.uncoordinatedDB
        func seed(_ name: String) async throws -> Recording {
            try await queue.write { db in
                let value = Recording(wavPath: root.appendingPathComponent(name + ".wav").path,
                    startedAt: Date(), canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 1, count: 32)),
                    canonicalPCMFrames: 160_000)
                try value.insert(db)
                return try XCTUnwrap(Recording.fetchOne(db, key: db.lastInsertedRowID))
            }
        }
        let enrolled = try await seed("enrollment")
        let target = try await seed("target")
        let id = try XCTUnwrap(target.id)
        let host = try DeviceID(Data(repeating: 2, count: 32))
        let client = try DeviceID(Data(repeating: 4, count: 32))
        let alice = try await store.createPerson(displayName: "Alice")
        let aliceVector = try QuantizedSpeakerEmbedding(dimensions: 3, values: Data([127,0,0]), scale: 0.5)
        let otherVector = try QuantizedSpeakerEmbedding(dimensions: 3, values: Data([0,127,0]), scale: 0.5)
        let enrollment = try SpeakerEvidenceSnapshot(canonicalRecordingID: enrolled.canonicalID,
            canonicalPCMHash: XCTUnwrap(enrolled.canonicalPCMHash), producerDeviceID: host,
            processingArtifactSHA256: Data(repeating: 3, count: 32), localClusterID: "enrolled-alice",
            embedding: aliceVector, modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        _ = try await store.retainSpeakerEvidence(enrollment)
        try await store.confirmSpeakerEvidence(sha256: enrollment.evidenceSHA256, personID: alice)
        let transcript = Data(#"{"speakers":[{"speaker":0,"startMs":0,"endMs":6000}],"joinedText":"Another person spoke here"}"#.utf8)
        let hostEvidence = try SpeakerEvidenceSnapshot(canonicalRecordingID: target.canonicalID,
            canonicalPCMHash: XCTUnwrap(target.canonicalPCMHash), producerDeviceID: host,
            processingArtifactSHA256: Data(SHA256.hash(data: transcript)), localClusterID: "host-speaker-0",
            embedding: otherVector, modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        try await store.updateProcessing(id: id, descriptor: .pending)
        _ = try await store.stageHostProcessedTranscriptIfNotReady(recordingID: id,
            text: "Another person spoke here", modelID: "test", structuredTranscriptData: transcript)
        _ = try await store.retainSpeakerEvidence(hostEvidence)
        _ = try await store.publishHostProcessedProjectionIfNotReady(recordingID: id,
            speakerEvidence: [0: hostEvidence.evidenceSHA256])
        let observation = try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: target.canonicalID,
            speakerIndex: 0, embedding: aliceVector, modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        let metadata = try await store.libraryMetadata()
        let session = HostAuthenticatedSession(context: AuthenticatedDeviceContext(
            libraryID: metadata.libraryID, hostAuthorityID: try HostAuthorityID(Data(repeating: 9, count: 32)),
            authenticatedDeviceID: client, grantID: .random(), grantEpoch: try GrantEpoch(1)),
            scopes: [.speakerObservationWrite], exactCapabilitiesBytes: Data([1]),
            capabilitiesSHA256: Data(repeating: 8, count: 32), protocolMinor: 0, selectedCodec: "caf-alac",
            selectedContainer: "caf", expiresAt: Date().addingTimeInterval(600))
        let service = HarcHostLibraryService(store: store)
        let beforePack = try await store.speakerRecognitionPack(dimensions: 3)
        let decision = try await service.submitSpeakerObservation(session: session, observation: observation)
        let replay = try await service.submitSpeakerObservation(session: session, observation: observation)
        XCTAssertEqual(replay, decision)
        let reopened = try await RecordingStore.onDisk(url: databaseURL)
        let durableReplay = try await reopened.retainUnmappedSpeakerObservation(observation, from: client)
        XCTAssertEqual(durableReplay, decision)
        let changed = try SpeakerEmbeddingObservation(operationID: observation.operationID,
            canonicalRecordingID: target.canonicalID, speakerIndex: 0, embedding: otherVector,
            modelID: "wespeaker_v2", speechDurationMs: 6000, segmentCount: 1)
        do {
            _ = try await reopened.retainUnmappedSpeakerObservation(changed, from: client)
            XCTFail("Changed evidence cannot replay an existing operation")
        } catch {}
        let after = try await store.fetch(id: id)
        let retained = try await store.retainedSpeakerEvidence(sha256: hostEvidence.evidenceSHA256)
        XCTAssertEqual(decision.disposition, .pendingReview)
        XCTAssertNil(after?.speakerNames[0])
        XCTAssertEqual(retained?.embedding, otherVector)
        XCTAssertNotEqual(retained?.embedding, observation.embedding)
        let afterPack = try await store.speakerRecognitionPack(dimensions: 3)
        XCTAssertEqual(afterPack.revision, beforePack.revision)
        XCTAssertEqual(afterPack.profiles, beforePack.profiles)
        let counts = try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM unmapped_speaker_observations"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embedding_observations"))
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        do {
            _ = try await store.retainUnmappedSpeakerObservation(observation, from: host)
            XCTFail("A different device cannot replay another device's observation")
        } catch {}

    }
}
