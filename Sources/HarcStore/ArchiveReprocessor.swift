import Foundation
import GRDB

/// Re-runs transcription over already-captured audio.
///
/// This is the compounding half of keeping the archive local: the WAVs never
/// left the machine, so when a better STT model ships every recording ever made
/// can be transcribed again for the cost of local compute. A hosted service
/// will not re-run three years of your meetings — it costs them real money per
/// customer — so their improvements only ever apply to what you record next.
///
/// The transcription engine is injected rather than imported so `HarcStore`
/// keeps no dependency on the STT client, and so the whole orchestration is
/// testable without loading a model.
public protocol ArchiveTranscriber: Sendable {
    /// Identifier of the engine doing the work; stored as provenance on each
    /// recording it processes.
    var modelID: String { get }
    /// Re-transcribe the WAV at `wavPath`, returning the transcript text.
    func retranscribe(wavPath: String) async throws -> String
}

public actor ArchiveReprocessor {
    public struct Progress: Sendable, Equatable {
        public var completed: Int
        public var total: Int
        public var failed: Int
        public var currentTitle: String?

        public init(completed: Int, total: Int, failed: Int, currentTitle: String?) {
            self.completed = completed
            self.total = total
            self.failed = failed
            self.currentTitle = currentTitle
        }

        public var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Transcripts replaced.
        public var reprocessed: Int
        /// Recordings whose audio was gone or whose transcription threw.
        public var failed: Int
        /// Skipped because the source WAV no longer exists on disk.
        public var missingAudio: Int
        /// True when the run ended early because it was cancelled.
        public var cancelled: Bool

        public init(reprocessed: Int, failed: Int, missingAudio: Int, cancelled: Bool) {
            self.reprocessed = reprocessed
            self.failed = failed
            self.missingAudio = missingAudio
            self.cancelled = cancelled
        }
    }

    private let store: RecordingStore
    private let fileExists: @Sendable (String) -> Bool
    private var cancelled = false

    public init(
        store: RecordingStore,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.store = store
        self.fileExists = fileExists
    }

    /// Ask an in-flight run to stop after the current recording. Deliberately
    /// not mid-recording: abandoning a transcript halfway would leave the row
    /// in a worse state than before the run started.
    public func cancel() {
        cancelled = true
    }

    /// Re-transcribe every recording not already produced by `transcriber`.
    ///
    /// Each recording is independent: a corrupt WAV or a daemon hiccup costs
    /// that one row and the run continues. A user who reprocesses a 400-meeting
    /// archive overnight should not wake to find it stopped on the third item.
    @discardableResult
    public func reprocessStale(
        using transcriber: any ArchiveTranscriber,
        limit: Int = 1000,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Outcome {
        cancelled = false

        let work: [Recording]
        do {
            work = try await store.recordingsNeedingReprocess(
                currentModelID: transcriber.modelID,
                limit: limit
            )
        } catch {
            return Outcome(reprocessed: 0, failed: 0, missingAudio: 0, cancelled: false)
        }

        var reprocessed = 0
        var failed = 0
        var missing = 0
        let total = work.count

        for recording in work {
            if cancelled {
                return Outcome(
                    reprocessed: reprocessed,
                    failed: failed,
                    missingAudio: missing,
                    cancelled: true
                )
            }
            guard let id = recording.id else { continue }

            onProgress?(Progress(
                completed: reprocessed + failed + missing,
                total: total,
                failed: failed,
                currentTitle: recording.displayTitle
            ))

            guard fileExists(recording.wavPath) else {
                // The library row outlives its audio if the user moved or
                // deleted the file. Not an error — just nothing to redo.
                missing += 1
                continue
            }

            do {
                let text = try await transcriber.retranscribe(wavPath: recording.wavPath)
                try await store.applyReprocessedTranscript(
                    recordingID: id,
                    text: text,
                    modelID: transcriber.modelID
                )
                reprocessed += 1
            } catch {
                failed += 1
            }
        }

        onProgress?(Progress(
            completed: reprocessed + failed + missing,
            total: total,
            failed: failed,
            currentTitle: nil
        ))

        return Outcome(
            reprocessed: reprocessed,
            failed: failed,
            missingAudio: missing,
            cancelled: false
        )
    }
}

// MARK: - Store support

public extension RecordingStore {

    /// Recordings whose transcript did not come from `currentModelID`.
    ///
    /// A NULL `stt_model_id` counts as stale: those transcripts predate
    /// provenance tracking, so they are the oldest in the library and the ones
    /// a newer engine improves most.
    func recordingsNeedingReprocess(
        currentModelID: String,
        limit: Int = 1000
    ) async throws -> [Recording] {
        try await db.read { db in
            try Recording.fetchAll(db, sql: """
                SELECT * FROM recordings
                WHERE deleted_at IS NULL
                  AND (stt_model_id IS NULL OR stt_model_id <> ?)
                ORDER BY started_at DESC
                LIMIT ?
                """, arguments: [currentModelID, limit])
        }
    }

    /// How many recordings would a reprocess run touch. Cheap enough to show
    /// in Settings next to the button.
    func reprocessBacklogCount(currentModelID: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM recordings
                WHERE deleted_at IS NULL
                  AND (stt_model_id IS NULL OR stt_model_id <> ?)
                """, arguments: [currentModelID]) ?? 0
        }
    }

    /// Replace a transcript with a freshly produced one and record which engine
    /// made it.
    ///
    /// Clears `chunks_indexed_at` in the same transaction: the text just
    /// changed underneath the vector index, and a stale index is worse than no
    /// index — it returns passages that are no longer in the transcript.
    func applyReprocessedTranscript(
        recordingID: Int64,
        text: String,
        modelID: String,
        now: Date = Date()
    ) async throws {
        // Milliseconds, not a Date: `transcribed_at` is an INTEGER column and
        // Recording decodes it as Int64. Handing GRDB a Date here would store a
        // date string that silently decodes back as nil.
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        try await db.write { db in
            let count = try Recording.filter(key: recordingID).updateAll(
                db,
                [
                    Recording.Columns.transcriptText.set(to: text),
                    Recording.Columns.sttModelID.set(to: modelID),
                    Recording.Columns.transcribedAt.set(to: stamp),
                    Recording.Columns.chunksIndexedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: now),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
            // Chunks are keyed to the old text; drop them with the marker.
            try db.execute(
                sql: "DELETE FROM transcript_chunks WHERE recording_id = ?",
                arguments: [recordingID]
            )
            try Self.bumpRevisionAndAppendLibraryChange(
                in: db,
                recordingID: recordingID,
                changedAt: now
            )
        }
        // Keep the on-disk .md artifact in step with the DB, the same way every
        // other content mutation does. Best-effort: the write already
        // committed, and a projection failure must not undo it.
        if let refreshed = try? await fetch(id: recordingID) {
            OKFProjection.write(recording: refreshed)
        }
    }

    /// Mark a freshly captured recording with the engine that transcribed it,
    /// so it isn't immediately picked up as stale by a reprocess run.
    func setTranscriptionProvenance(
        recordingID: Int64,
        modelID: String,
        now: Date = Date()
    ) async throws {
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        try await db.write { db in
            let count = try Recording.filter(key: recordingID).updateAll(
                db,
                [
                    Recording.Columns.sttModelID.set(to: modelID),
                    Recording.Columns.transcribedAt.set(to: stamp),
                    Recording.Columns.updatedAt.set(to: now),
                ]
            )
            guard count > 0 else { return }
            try Self.bumpRevisionAndAppendLibraryChange(
                in: db,
                recordingID: recordingID,
                changedAt: now
            )
        }
    }
}
