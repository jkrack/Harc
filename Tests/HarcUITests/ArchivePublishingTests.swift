import Foundation
import Testing
import HarcStore
@testable import HarcUI

@Suite("Structured archive publication dispatch")
struct ArchivePublishingTests {
    @Test func archiveCountsOnlyCompletedPublicationAndContinuesAfterFailure() async throws {
        let store = try await RecordingStore.inMemory()
        for title in ["first", "fail", "last"] {
            _ = try await store.upsert(Recording(wavPath: "/tmp/archive-publish-\(title).wav", startedAt: Date(),
                title: title, transcriptText: "original"))
        }
        let publisher = PublishingArchiveTranscriber(modelID: "new-model") { recording, target in
            if recording.title == "fail" { throw StoreError.writeFailed("injected publication failure") }
            guard let id = recording.id else { throw StoreError.notFound }
            try await target.applyReprocessedTranscript(recordingID: id, text: "published", modelID: "new-model",
                expectedRevision: recording.revision)
        }
        let worker = ArchiveReprocessor(store: store, fileExists: { _ in true })
        let outcome = await worker.reprocessStale(using: publisher)
        #expect(outcome.reprocessed == 2)
        #expect(outcome.failed == 1)
        for recording in try await store.fetchAll() {
            #expect(recording.transcriptText == (recording.title == "fail" ? "original" : "published"))
            #expect(recording.sttModelID == (recording.title == "fail" ? nil : "new-model"))
        }
    }

    private struct EditingTranscriber: ArchiveTranscriber {
        let modelID = "new-model"
        let store: RecordingStore
        let recordingID: Int64
        func retranscribe(wavPath: String) async throws -> String {
            try await store.updateSpeakerNames(id: recordingID, names: [0: "Edited during inference"])
            return "replacement"
        }
    }

    @Test func legacyAdapterCannotOverwriteARecordingEditedDuringInference() async throws {
        let store = try await RecordingStore.inMemory()
        let recording = try await store.upsert(Recording(wavPath: "/tmp/archive-edit-during-inference.wav",
            startedAt: Date(), transcriptText: "original"))
        let id = try #require(recording.id)
        let worker = ArchiveReprocessor(store: store, fileExists: { _ in true })
        let outcome = await worker.reprocessStale(using: EditingTranscriber(store: store, recordingID: id))
        #expect(outcome.reprocessed == 0)
        #expect(outcome.failed == 1)
        let saved = try await store.fetch(id: id)
        #expect(saved?.transcriptText == "original")
        #expect(saved?.speakerNames[0] == "Edited during inference")
    }
}
