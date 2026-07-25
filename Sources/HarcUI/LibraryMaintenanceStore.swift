import Foundation
import Combine
import HarcStore

/// Drives the two whole-library operations that only make sense locally:
/// re-transcribing the archive when a better engine ships, and building the
/// search index over transcripts already on disk.
///
/// Both are long-running, cancellable, and safe to interrupt — the user closes
/// Settings mid-run far more often than they wait for one to finish. Neither
/// blocks recording; both are explicitly user-initiated rather than something
/// Harc decides to do to a warm laptop on battery.
@MainActor
public final class LibraryMaintenanceStore: ObservableObject {

    public enum Job: Equatable, Sendable {
        case idle
        case reprocessing(ArchiveReprocessor.Progress)
        case indexing(completed: Int, total: Int)

        public var isRunning: Bool { self != .idle }
    }

    @Published public private(set) var job: Job = .idle
    /// Recordings whose transcript came from an older engine.
    @Published public private(set) var reprocessBacklog: Int = 0
    /// Recordings with a transcript but no search index.
    @Published public private(set) var indexBacklog: Int = 0
    /// Outcome of the last reprocess run, for a result line in Settings.
    @Published public private(set) var lastOutcome: String?

    /// Optional because Settings can be opened before the database finishes
    /// bootstrapping. Every operation no-ops until it lands rather than
    /// pretending an empty library.
    private let store: RecordingStore?
    private let embedder: any TextEmbedder
    /// Supplies the current STT engine. A closure because the engine identity
    /// can change under the app (model swap) without this object being rebuilt.
    private let transcriberProvider: @MainActor () -> (any ArchiveTranscriber)?
    private var reprocessor: ArchiveReprocessor?
    private var activeTask: Task<Void, Never>?

    public init(
        store: RecordingStore?,
        embedder: any TextEmbedder = HashedLexicalEmbedder(),
        transcriberProvider: @escaping @MainActor () -> (any ArchiveTranscriber)?
    ) {
        self.store = store
        self.embedder = embedder
        self.transcriberProvider = transcriberProvider
    }

    /// Recompute both backlogs. Cheap enough to call whenever Settings appears.
    public func refreshBacklogs() async {
        guard let store else { return }
        if let transcriber = transcriberProvider() {
            reprocessBacklog = (try? await store.reprocessBacklogCount(
                currentModelID: transcriber.modelID
            )) ?? 0
        } else {
            reprocessBacklog = 0
        }
        indexBacklog = ((try? await store.recordingsNeedingIndex()) ?? []).count
    }

    // MARK: - Reprocess

    public func startReprocess() {
        guard !job.isRunning, let store, let transcriber = transcriberProvider() else { return }

        let reprocessor = ArchiveReprocessor(store: store)
        self.reprocessor = reprocessor
        job = .reprocessing(.init(completed: 0, total: reprocessBacklog, failed: 0, currentTitle: nil))
        lastOutcome = nil

        activeTask = Task { [weak self] in
            let outcome = await reprocessor.reprocessStale(
                using: transcriber,
                onProgress: { progress in
                    // Hop to the main actor to publish; the callback arrives on
                    // the reprocessor's executor.
                    Task { @MainActor in
                        guard let store = self, store.job.isRunning else { return }
                        store.job = .reprocessing(progress)
                    }
                }
            )
            await MainActor.run {
                self?.finishReprocess(outcome)
            }
        }
    }

    private func finishReprocess(_ outcome: ArchiveReprocessor.Outcome) {
        job = .idle
        reprocessor = nil
        var parts: [String] = []
        if outcome.reprocessed > 0 {
            parts.append("\(outcome.reprocessed) re-transcribed")
        }
        if outcome.failed > 0 { parts.append("\(outcome.failed) failed") }
        if outcome.missingAudio > 0 { parts.append("\(outcome.missingAudio) missing audio") }
        if outcome.cancelled { parts.append("stopped early") }
        lastOutcome = parts.isEmpty ? "Everything was already current." : parts.joined(separator: " · ")
        Task { await refreshBacklogs() }
    }

    // MARK: - Search index

    public func startIndexing() {
        guard !job.isRunning, store != nil else { return }
        job = .indexing(completed: 0, total: indexBacklog)
        lastOutcome = nil

        activeTask = Task { [weak self] in
            guard let self else { return }
            guard let store = self.store else { return }
            let pending = (try? await store.recordingsNeedingIndex()) ?? []
            var done = 0
            for recording in pending {
                if Task.isCancelled { break }
                guard let id = recording.id,
                      let text = recording.transcriptText,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }

                let durationMs = recording.endedAt.map {
                    Int($0.timeIntervalSince(recording.startedAt) * 1000)
                }
                // Per-recording failure is survivable: skip and keep going
                // rather than abandoning the rest of the library.
                _ = try? await store.indexTranscript(
                    recordingID: id,
                    text: text,
                    durationMs: durationMs,
                    embedder: self.embedder
                )
                done += 1
                let snapshot = done
                let total = pending.count
                await MainActor.run { [weak self] in
                    guard let self, self.job.isRunning else { return }
                    self.job = .indexing(completed: snapshot, total: total)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.job = .idle
                self.lastOutcome = done > 0
                    ? "\(done) recording\(done == 1 ? "" : "s") indexed for search."
                    : "Everything was already indexed."
                Task { await self.refreshBacklogs() }
            }
        }
    }

    /// Index a single recording — the post-stop hook, so new recordings are
    /// searchable without waiting for a manual pass.
    public func indexNewRecording(id: Int64, text: String, durationMs: Int?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let store else { return }
        Task { [store, embedder] in
            _ = try? await store.indexTranscript(
                recordingID: id,
                text: text,
                durationMs: durationMs,
                embedder: embedder
            )
        }
    }

    // MARK: - Cancellation

    public func cancel() {
        activeTask?.cancel()
        if let reprocessor {
            Task { await reprocessor.cancel() }
        }
        // `.indexing` has no in-flight callback to land the final state, so
        // settle here; reprocess finishes through its own completion path.
        if case .indexing = job {
            job = .idle
            lastOutcome = "Stopped early."
            Task { await refreshBacklogs() }
        }
    }

    /// The embedder search should use, so the query is embedded by the same
    /// model the index was built with.
    public var searchEmbedder: any TextEmbedder { embedder }
}
