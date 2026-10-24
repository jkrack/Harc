import Foundation
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Pending Library metadata independent of transcription")
struct PendingLibraryProjectionTests {
    @Test("A failed processing row remains in the path-free Library snapshot and changes")
    func failedProcessingRemainsVisible() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = Recording(
            wavPath: "/private/tmp/SYNTHETIC_PATH_MUST_NOT_ESCAPE.wav",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let inserted = try await store.upsert(recording)
        let id = try #require(inserted.id)
        let hash = try CanonicalPCMHash(Data(repeating: 0x23, count: 32))
        try await store.setCanonicalPCM(id: id, hash: hash, totalFrames: 91_200)
        let beforeFailure = try await store.libraryMetadata().currentChangeCursor

        try await store.updateProcessing(
            id: id,
            descriptor: ProcessingDescriptor(
                state: .failedRecoverable,
                failure: ProcessingFailure(
                    code: "host.processing_retry",
                    message: "Synthetic retry"
                )
            )
        )
        try await store.updateProjection(id: id, descriptor: .pending)

        let snapshot = try await store.anchoredLibrarySnapshot()
        let row = try #require(snapshot.recordings.first {
            $0.canonicalID == inserted.canonicalID
        })
        #expect(row.processing.state == .failedRecoverable)
        #expect(row.projection.state == .pending)
        #expect(row.canonicalAudio.totalFrames == 91_200)
        #expect(row.canonicalAudio.pcmSHA256 == hash)
        let serialized = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: serialized, as: UTF8.self)
            .contains("SYNTHETIC_PATH_MUST_NOT_ESCAPE"))

        let changes = try await store.libraryChanges(after: beforeFailure)
        #expect(changes.contains {
            $0.canonicalID == inserted.canonicalID && $0.operation == .upsert
        })
    }
}
