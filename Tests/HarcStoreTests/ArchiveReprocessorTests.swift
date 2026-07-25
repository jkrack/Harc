import Testing
import Foundation
@testable import HarcStore

@Suite("ArchiveReprocessor")
struct ArchiveReprocessorTests {

    /// Records what it was asked to do and returns scripted text, so the whole
    /// orchestration is exercised without loading an STT model.
    actor FakeTranscriber: ArchiveTranscriber {
        nonisolated let modelID: String
        private let output: String
        private let failingPaths: Set<String>
        private(set) var seen: [String] = []

        init(modelID: String, output: String = "reprocessed text", failingPaths: Set<String> = []) {
            self.modelID = modelID
            self.output = output
            self.failingPaths = failingPaths
        }

        func retranscribe(wavPath: String) async throws -> String {
            seen.append(wavPath)
            if failingPaths.contains(wavPath) {
                throw StoreError.notFound
            }
            return output
        }
    }

    private func makeRecording(_ title: String, at offset: TimeInterval) -> Recording {
        Recording(
            wavPath: "/tmp/harc-reproc-\(UUID().uuidString.prefix(8)).wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            endedAt: nil,
            title: title,
            transcriptText: "original text"
        )
    }

    /// Treat every path as present unless explicitly absent.
    private func reprocessor(store: RecordingStore, missing: Set<String> = []) -> ArchiveReprocessor {
        ArchiveReprocessor(store: store, fileExists: { !missing.contains($0) })
    }

    @Test("recordings with no provenance count as stale")
    func nullProvenanceIsStale() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(makeRecording("Old", at: 0))

        let stale = try await store.recordingsNeedingReprocess(currentModelID: "parakeet-v3")
        #expect(stale.count == 1)
        #expect(try await store.reprocessBacklogCount(currentModelID: "parakeet-v3") == 1)
    }

    @Test("recordings already on the current model are not stale")
    func currentModelIsNotStale() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(makeRecording("Fresh", at: 0))
        try await store.setTranscriptionProvenance(recordingID: rec.id!, modelID: "parakeet-v3")

        #expect(try await store.recordingsNeedingReprocess(currentModelID: "parakeet-v3").isEmpty)
        // ...but a newer engine makes it stale again.
        #expect(try await store.recordingsNeedingReprocess(currentModelID: "parakeet-v4").count == 1)
    }

    @Test("reprocessing replaces the transcript and stamps provenance")
    func reprocessReplacesTranscript() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(makeRecording("Meeting", at: 0))
        let transcriber = FakeTranscriber(modelID: "parakeet-v4", output: "much better text")

        let outcome = await reprocessor(store: store)
            .reprocessStale(using: transcriber)

        #expect(outcome.reprocessed == 1)
        #expect(outcome.failed == 0)
        #expect(!outcome.cancelled)

        let updated = try await store.fetch(id: rec.id!)
        #expect(updated?.transcriptText == "much better text")
        #expect(updated?.sttModelID == "parakeet-v4")
        #expect(updated?.transcribedAt != nil)

        // Now current — a second run finds nothing to do.
        let second = await reprocessor(store: store).reprocessStale(using: transcriber)
        #expect(second.reprocessed == 0)
    }

    @Test("reprocessing invalidates the semantic index for that recording")
    func reprocessInvalidatesChunkIndex() async throws {
        let store = try await RecordingStore.inMemory()
        let embedder = HashedLexicalEmbedder()
        let rec = try await store.upsert(makeRecording("Indexed", at: 0))

        try await store.indexTranscript(
            recordingID: rec.id!,
            text: "the original database migration discussion",
            embedder: embedder
        )
        #expect(try await !store.semanticSearch(query: "database migration", embedder: embedder).isEmpty)
        #expect(try await store.fetch(id: rec.id!)?.chunksIndexedAt != nil)

        await reprocessor(store: store)
            .reprocessStale(using: FakeTranscriber(modelID: "parakeet-v4", output: "entirely different words now"))

        // The old passages describe text that no longer exists. A stale index
        // is worse than none — it returns things the transcript doesn't say.
        #expect(try await store.semanticSearch(query: "database migration", embedder: embedder).isEmpty)
        #expect(try await store.fetch(id: rec.id!)?.chunksIndexedAt == nil)
        // And it's queued for re-indexing.
        let pending = try await store.recordingsNeedingIndex().compactMap(\.id)
        #expect(pending.contains(rec.id!))
    }

    @Test("one failure does not stop the run")
    func failureIsolation() async throws {
        let store = try await RecordingStore.inMemory()
        let good1 = try await store.upsert(makeRecording("A", at: 0))
        let bad = try await store.upsert(makeRecording("B", at: 100))
        let good2 = try await store.upsert(makeRecording("C", at: 200))

        let transcriber = FakeTranscriber(
            modelID: "parakeet-v4",
            output: "new text",
            failingPaths: [bad.wavPath]
        )

        let outcome = await reprocessor(store: store).reprocessStale(using: transcriber)

        #expect(outcome.reprocessed == 2)
        #expect(outcome.failed == 1)
        // The neighbours were still done — an overnight run over 400 meetings
        // must not stop on the third.
        #expect(try await store.fetch(id: good1.id!)?.transcriptText == "new text")
        #expect(try await store.fetch(id: good2.id!)?.transcriptText == "new text")
        // The failure kept its original transcript rather than losing it.
        #expect(try await store.fetch(id: bad.id!)?.transcriptText == "original text")
        #expect(try await store.fetch(id: bad.id!)?.sttModelID == nil)
    }

    @Test("recordings whose audio is gone are skipped, not failed")
    func missingAudioIsSkipped() async throws {
        let store = try await RecordingStore.inMemory()
        let present = try await store.upsert(makeRecording("Has audio", at: 0))
        let gone = try await store.upsert(makeRecording("Audio deleted", at: 100))

        let outcome = await reprocessor(store: store, missing: [gone.wavPath])
            .reprocessStale(using: FakeTranscriber(modelID: "parakeet-v4"))

        #expect(outcome.reprocessed == 1)
        #expect(outcome.missingAudio == 1)
        #expect(outcome.failed == 0)
        #expect(try await store.fetch(id: present.id!)?.sttModelID == "parakeet-v4")
        #expect(try await store.fetch(id: gone.id!)?.transcriptText == "original text")
    }

    @Test("progress is reported and reaches completion")
    func progressReporting() async throws {
        let store = try await RecordingStore.inMemory()
        for i in 0..<3 { _ = try await store.upsert(makeRecording("R\(i)", at: Double(i) * 100)) }

        final class Box: @unchecked Sendable { var values: [ArchiveReprocessor.Progress] = [] }
        let box = Box()

        let outcome = await reprocessor(store: store).reprocessStale(
            using: FakeTranscriber(modelID: "parakeet-v4"),
            onProgress: { box.values.append($0) }
        )

        #expect(outcome.reprocessed == 3)
        #expect(!box.values.isEmpty)
        #expect(box.values.allSatisfy { $0.total == 3 })
        #expect(box.values.last?.completed == 3)
        #expect(box.values.last?.fraction == 1.0)
    }

    @Test("cancelling stops the run and reports it")
    func cancellation() async throws {
        let store = try await RecordingStore.inMemory()
        for i in 0..<5 { _ = try await store.upsert(makeRecording("R\(i)", at: Double(i) * 100)) }

        let reproc = reprocessor(store: store)
        // Cancel from the progress callback once the first item is done, so the
        // run observes the flag between recordings rather than mid-transcript.
        let outcome = await reproc.reprocessStale(
            using: FakeTranscriber(modelID: "parakeet-v4"),
            onProgress: { progress in
                if progress.completed >= 1 { Task { await reproc.cancel() } }
            }
        )

        #expect(outcome.reprocessed >= 1)
        #expect(outcome.reprocessed < 5 || outcome.cancelled)
    }

    @Test("an empty library reprocesses cleanly")
    func emptyLibrary() async throws {
        let store = try await RecordingStore.inMemory()
        let outcome = await reprocessor(store: store)
            .reprocessStale(using: FakeTranscriber(modelID: "parakeet-v4"))

        #expect(outcome == ArchiveReprocessor.Outcome(
            reprocessed: 0, failed: 0, missingAudio: 0, cancelled: false
        ))
    }

    @Test("soft-deleted recordings are never reprocessed")
    func deletedAreExcluded() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(makeRecording("Deleted", at: 0))
        try await store.softDelete(id: rec.id!)

        let outcome = await reprocessor(store: store)
            .reprocessStale(using: FakeTranscriber(modelID: "parakeet-v4"))
        #expect(outcome.reprocessed == 0)
        #expect(try await store.reprocessBacklogCount(currentModelID: "parakeet-v4") == 0)
    }
}
