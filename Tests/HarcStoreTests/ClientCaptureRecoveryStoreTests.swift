import Foundation
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Client capture local Library recovery")
struct ClientCaptureRecoveryStoreTests {
    @Test("verified Client capture is inserted once with durable identity")
    func insertsIdempotently() async throws {
        let store = try await RecordingStore.inMemory()
        let facts = try fixtureFacts()

        let first = try await reconcile(store: store, facts: facts)
        let second = try await reconcile(store: store, facts: facts)

        #expect(first.inserted)
        #expect(!second.inserted)
        #expect(first.recording.id == second.recording.id)
        #expect(second.recording.originID == facts.origin)
        #expect(second.recording.canonicalPCMHash == facts.hash)
        #expect(second.recording.canonicalPCMFrames == 16_000)
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("a later local transcript enriches the visible recovered row")
    func adoptsTranscriptAfterVisibility() async throws {
        let store = try await RecordingStore.inMemory()
        let facts = try fixtureFacts()
        _ = try await reconcile(store: store, facts: facts)

        let completed = try await reconcile(
            store: store,
            facts: facts,
            transcript: "locally recovered words"
        )

        #expect(!completed.inserted)
        #expect(completed.recording.transcriptText == "locally recovered words")
        #expect(completed.recording.sttModelID == "parakeet-test")
        #expect(completed.recording.jsonPath?.hasSuffix(".json") == true)
        #expect(try await store.fetchAll().count == 1)
    }

    @Test("an origin already bound to different PCM remains fail closed")
    func rejectsAudioConflict() async throws {
        let store = try await RecordingStore.inMemory()
        let facts = try fixtureFacts()
        _ = try await reconcile(store: store, facts: facts)
        let otherHash = try CanonicalPCMHash(Data(repeating: 0x44, count: 32))

        await #expect(throws: StoreError.canonicalPCMHashConflict) {
            _ = try await store.reconcileClientCapture(
                originID: facts.origin,
                canonicalPCMHash: otherHash,
                canonicalPCMFrames: 16_000,
                masterURL: facts.master,
                startedAt: facts.started,
                endedAt: facts.started.addingTimeInterval(1),
                transcriptText: nil,
                transcriptJSONURL: nil,
                transcriptMarkdownURL: nil,
                sttModelID: nil,
                transcribedAt: nil
            )
        }
    }

    private struct Facts {
        let origin: OriginRecordingID
        let hash: CanonicalPCMHash
        let master: URL
        let started: Date
    }

    private func fixtureFacts() throws -> Facts {
        Facts(
            origin: OriginRecordingID(
                deviceID: try DeviceID(Data(repeating: 0x21, count: 32)),
                recordingUUID: UUID(
                    uuidString: "11111111-2222-4333-8444-555555555555"
                )!
            ),
            hash: try CanonicalPCMHash(Data(repeating: 0x31, count: 32)),
            master: URL(fileURLWithPath: "/tmp/client-recovered.wav"),
            started: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func reconcile(
        store: RecordingStore,
        facts: Facts,
        transcript: String? = nil
    ) async throws -> ClientCaptureLibraryResult {
        try await store.reconcileClientCapture(
            originID: facts.origin,
            canonicalPCMHash: facts.hash,
            canonicalPCMFrames: 16_000,
            masterURL: facts.master,
            startedAt: facts.started,
            endedAt: facts.started.addingTimeInterval(1),
            transcriptText: transcript,
            transcriptJSONURL: transcript.map { _ in
                URL(fileURLWithPath: "/tmp/client-recovered.json")
            },
            transcriptMarkdownURL: transcript.map { _ in
                URL(fileURLWithPath: "/tmp/client-recovered.md")
            },
            sttModelID: transcript == nil ? nil : "parakeet-test",
            transcribedAt: transcript == nil ? nil : facts.started
        )
    }
}
