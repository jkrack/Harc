import Foundation
import AVFoundation
import HarcCore

/// Protocol boundary for testing — any client that can transcribe a WAV path.
public protocol TranscribingClient: Sendable {
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult
}

/// Protocol boundary for testing — any client that can run a full-WAV
/// diarization pass at end-of-recording.
public protocol DiarizingClient: Sendable {
    func diarize(audioPath: String) async throws -> DiarizeResult
}

extension HarcSTTClient: TranscribingClient {}
extension HarcSTTClient: DiarizingClient {}

/// Result bundle returned from `finalize`. The caller persists the embeddings
/// alongside the recording row in a single transactional ingest.
public struct ChunkedTranscriberFinalize: Sendable {
    public let transcript: SessionTranscript
    /// Per-speaker WeSpeaker centroid rows from the post-stop diarize pass.
    /// Empty when diarization failed or returned nothing.
    public let speakerEmbeddings: [SpeakerEmbeddingRow]
    /// Set when the diarize pass failed; the transcript's text + words are
    /// still complete. UI layers surface a retry affordance from this.
    public let diarizationError: String?

    public init(
        transcript: SessionTranscript,
        speakerEmbeddings: [SpeakerEmbeddingRow],
        diarizationError: String?
    ) {
        self.transcript = transcript
        self.speakerEmbeddings = speakerEmbeddings
        self.diarizationError = diarizationError
    }
}

/// Drives a WAVChunker, dispatches each chunk to a TranscribingClient,
/// assembles a session transcript. After tail flush, calls `diarize` once
/// on the full WAV via the DiarizingClient and uses its segments as the
/// authoritative speaker labels for the recording.
/// A stretch of the recording that produced no transcript after all
/// retries. The audio still exists in the master WAV.
public struct FailedChunkRange: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let reason: String

    /// The marker inserted into the transcript where the audio should be —
    /// a hole the user can see beats a silence the user discovers in a
    /// meeting's minutes three weeks later.
    var markerText: String {
        func stamp(_ ms: Int) -> String {
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "[\(stamp(startMs))–\(stamp(endMs)) could not be transcribed — Re-transcribe in Settings → Transcription repairs this from the saved audio]"
    }
}

public actor ChunkedTranscriber {
    private let client: any TranscribingClient
    private let diarizer: (any DiarizingClient)?
    private let vadEnabled: Bool
    private let chunkDurationSeconds: Double
    private let pollIntervalSeconds: Double
    private let vocabulary: Vocabulary
    private let chunkRetryDelaySeconds: Double
    private let livePreviewIntervalSeconds: Double
    private let livePreviewWindowSeconds: Double

    nonisolated(unsafe) private let assembler = TranscriptAssembler()
    private var chunker: WAVChunker?
    private var audioURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewInFlight = false
    private var lastComposedPreview: String?
    private var stopped = false

    /// Chunks whose transcription failed and are awaiting another attempt.
    ///
    /// Every failure is retried, not just `model_not_loaded`. The original
    /// policy retried only the model-loading case and *deleted the chunk WAV*
    /// for anything else — a daemon timeout or socket hiccup silently erased
    /// minutes of a meeting from the transcript, with one line on stderr as
    /// the only witness. A field recording produced a transcript with a
    /// seven-and-a-half-minute hole this way.
    private struct PendingChunkRetry {
        let chunk: WAVChunker.Chunk
        var attempts: Int
        var maxAttempts: Int
        var retryDelay: Double
        var nextAttemptAt: Date
        var lastError: String
    }
    private var retryQueue: [PendingChunkRetry] = []

    /// Time ranges whose audio never produced a transcript, after all
    /// retries. Recorded so the hole is visible in the transcript itself and
    /// repairable via the archive re-transcribe — the durable master WAV
    /// still has the audio; only this pass lost it.
    public private(set) var failedRanges: [FailedChunkRange] = []
    /// 40 × 15s default delay ≈ 10 minutes of cover — enough for the
    /// ~460 MB first-run model download on a slow connection.
    static let maxChunkRetries = 40
    /// Transient failures (timeouts, socket errors) either recover fast or
    /// not at all — four tries at a shorter delay.
    static let maxTransientRetries = 4
    /// Below this, a VAD-gated chunk is suspect. Engaged speech runs
    /// 700–900 chars/min; even a sparse meeting minute clears 150. The
    /// field recording's VAD-shredded chunks all sat under 105.
    static let suspiciouslySparseCharsPerMinute: Double = 120
    /// Bounded patience at finalize: keep retrying `model_not_loaded`
    /// chunks for up to this long after stop before giving up. Reliability
    /// over stop-latency, per the project north star.
    static let finalizeRetryBudgetSeconds: Double = 180

    public let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    public init(
        client: any TranscribingClient,
        diarizer: (any DiarizingClient)? = nil,
        vadEnabled: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0,
        vocabulary: Vocabulary = .empty,
        chunkRetryDelaySeconds: Double = 15.0,
        livePreviewIntervalSeconds: Double = 5.0,
        livePreviewWindowSeconds: Double = 30.0
    ) {
        self.client = client
        self.diarizer = diarizer
        self.vadEnabled = vadEnabled
        self.chunkDurationSeconds = chunkDurationSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.vocabulary = vocabulary
        self.chunkRetryDelaySeconds = chunkRetryDelaySeconds
        self.livePreviewIntervalSeconds = livePreviewIntervalSeconds
        self.livePreviewWindowSeconds = livePreviewWindowSeconds
        let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
        self.updates = stream
        self.updatesContinuation = cont
    }

    public func start(audioURL: URL) {
        self.audioURL = audioURL
        self.chunker = WAVChunker(audioURL: audioURL, chunkDurationSeconds: chunkDurationSeconds)
        self.pumpTask = Task.detached { [self] in await self.pump() }
        if livePreviewIntervalSeconds > 0 {
            self.previewTask = Task.detached { [self] in await self.previewPump() }
        }
    }

    /// Stops polling, processes any remaining tail chunk, runs the full-WAV
    /// diarize pass, and returns the assembled transcript + embeddings.
    public func finalize(startedAt: Date, endedAt: Date) async throws -> ChunkedTranscriberFinalize {
        stopped = true
        pumpTask?.cancel()
        previewTask?.cancel()
        _ = await pumpTask?.value
        _ = await previewTask?.value
        pumpTask = nil
        previewTask = nil

        if let chunker {
            do {
                if let tail = try await chunker.flush() {
                    try await processChunk(tail)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-client: tail chunk failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        // Drain chunks still waiting on the model (first-run download):
        // keep retrying within a bounded budget so the transcript comes
        // back complete. Reliability over stop-latency — the retries only
        // spin while the daemon reports model_not_loaded.
        let drainDeadline = Date().addingTimeInterval(Self.finalizeRetryBudgetSeconds)
        while !retryQueue.isEmpty, Date() < drainDeadline {
            let wait = max(0, retryQueue.map(\.nextAttemptAt).min()!.timeIntervalSinceNow)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 5) * 1_000_000_000))
            }
            await processDueRetries()
        }
        for abandoned in retryQueue {
            FileHandle.standardError.write(Data(
                "harc-client: giving up on chunk \(abandoned.chunk.startMs)ms after retry budget\n".utf8
            ))
            failedRanges.append(FailedChunkRange(
                startMs: abandoned.chunk.startMs,
                endMs: abandoned.chunk.endMs,
                reason: abandoned.lastError
            ))
            try? FileManager.default.removeItem(at: abandoned.chunk.audioURL)
        }
        retryQueue = []

        // Holes become part of the transcript, in spoken order, where the
        // missing audio belongs — visible in the pane, the .md, and every
        // export, each naming the repair path.
        for range in failedRanges {
            assembler.add(ChunkResult(
                startMs: range.startMs,
                endMs: range.endMs,
                text: range.markerText,
                words: [],
                speakers: [],
                processingMs: 0
            ))
        }

        updatesContinuation.finish()

        var assembled = assembler.finalize(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioURL?.path ?? ""
        )
        assembled.joinedText = VocabularyReplacer.apply(assembled.joinedText, using: vocabulary)

        // Full-WAV diarization pass. On failure, return text + words and
        // surface the error string so UI layers can offer a retry.
        var speakerEmbeddings: [SpeakerEmbeddingRow] = []
        var diarizationError: String?
        if let diarizer, let url = audioURL {
            do {
                let result = try await diarizer.diarize(audioPath: url.path)
                assembled.speakers = result.segments
                speakerEmbeddings = result.speakers
            } catch {
                diarizationError = error.localizedDescription
                FileHandle.standardError.write(Data(
                    "harc-client: post-stop diarize failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return ChunkedTranscriberFinalize(
            transcript: assembled,
            speakerEmbeddings: speakerEmbeddings,
            diarizationError: diarizationError
        )
    }

    /// Live-preview pass: every few seconds, transcribe a rolling window of
    /// the most recent audio and splice its tail onto the committed text, so
    /// the live pane trails the meeting by seconds instead of a chunk. The
    /// preview never touches the assembler — the durable transcript is built
    /// only from full chunks, and a failed preview pass is simply skipped.
    private func previewPump() async {
        while !Task.isCancelled, !stopped {
            try? await Task.sleep(nanoseconds: UInt64(livePreviewIntervalSeconds * 1_000_000_000))
            guard !Task.isCancelled, !stopped else { return }
            await emitPreview()
        }
    }

    private func emitPreview() async {
        guard let chunker, !previewInFlight else { return }
        previewInFlight = true
        defer { previewInFlight = false }

        // Anchor the window at the committed boundary so the preview text is
        // entirely new — no timestamp trimming, which would have to reason
        // about sub-word tokens and would garble words at the cut. The cap
        // only matters when chunk retries let the uncommitted span grow past
        // two chunks; previews then cover the most recent stretch and the
        // retry machinery owns the rest.
        let committedEndMs = assembler.currentEndMs
        guard let window = try? await chunker.previewWindow(
            fromMs: committedEndMs, maxSeconds: chunkDurationSeconds * 2
        ) else { return }
        defer { try? FileManager.default.removeItem(at: window.audioURL) }

        // No VAD on preview passes: a minute of audio costs well under a
        // second on the ANE either way, and far-field VAD shredding would
        // make the pane lie.
        guard let result = try? await client.transcribe(
            audioPath: window.audioURL.path, diarize: false, vad: false
        ) else { return }

        // If a chunk committed while the transcribe ran, this window's text
        // now overlaps committed text — skip; the next tick re-covers.
        guard assembler.currentEndMs == committedEndMs else { return }

        guard let composed = Self.composeLivePreview(
            committedText: assembler.currentJoinedText,
            previewText: result.text
        ), composed != lastComposedPreview else { return }
        lastComposedPreview = composed
        updatesContinuation.yield(TranscriptUpdate(
            chunkIndex: composed.split(separator: " ").count,
            joinedTextSoFar: composed
        ))
    }

    /// Appends a preview transcription — which by construction covers only
    /// audio past the committed boundary — onto the committed transcript.
    /// Returns nil when the preview says nothing: emit no update this tick.
    static func composeLivePreview(committedText: String, previewText: String) -> String? {
        let preview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return nil }
        return committedText.isEmpty ? preview : committedText + " " + preview
    }

    private func pump() async {
        guard let chunker else { return }
        while !Task.isCancelled, !stopped {
            await processDueRetries()
            do {
                if let chunk = try await chunker.nextChunk() {
                    try await processChunk(chunk)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-client: chunk transcription failed: \(error.localizedDescription)\n".utf8
                ))
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    /// Re-attempt queued `model_not_loaded` chunks whose backoff elapsed.
    private func processDueRetries() async {
        guard !retryQueue.isEmpty else { return }
        let now = Date()
        var stillPending: [PendingChunkRetry] = []
        let due = retryQueue
        retryQueue = []
        for entry in due {
            guard entry.nextAttemptAt <= now else {
                stillPending.append(entry)
                continue
            }
            do {
                try await processChunk(entry.chunk, retryAttempt: entry.attempts)
            } catch {
                // processChunk re-enqueued it (model still loading) or gave
                // up and cleaned up; either way nothing more to do here.
            }
        }
        retryQueue.append(contentsOf: stillPending)
    }

    /// Cheap RMS gate for the VAD fallback: read the 16 kHz mono Int16
    /// chunk and ask whether anything in it rises above a quiet-room floor.
    /// −50 dBFS is far below any audible speaker — even one across a big
    /// room — but above electrical noise, so true silence never triggers
    /// the second pass.
    static func hasAudibleEnergy(_ url: URL, thresholdDBFS: Double = -50) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, Int64(16_000 * 120)))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return false }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return false }
        var sum: Double = 0
        for i in 0..<n {
            let v = Double(data[0][i])
            sum += v * v
        }
        let rms = (sum / Double(n)).squareRoot()
        guard rms > 0 else { return false }
        let dbfs = 20 * log10(rms)
        return dbfs > thresholdDBFS
    }

    private static func isModelNotLoaded(_ error: Error) -> Bool {
        if case ClientError.transcribeFailed(let code, _) = error {
            return code == "model_not_loaded"
        }
        return false
    }

    private func processChunk(_ chunk: WAVChunker.Chunk, retryAttempt: Int = 0) async throws {
        // Per-chunk diarization is OFF — labels come from the post-stop
        // full-WAV diarize call in `finalize`.
        var result: TranscribeResult
        do {
            result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: false, vad: vadEnabled)
        } catch {
            let isModelWait = Self.isModelNotLoaded(error)
            let maxAttempts = isModelWait ? Self.maxChunkRetries : Self.maxTransientRetries
            if retryAttempt < maxAttempts {
                // Keep the chunk WAV and retry — every failure, not just the
                // model-loading one. Deleting on first failure is how minutes
                // of a meeting used to vanish with one stderr line as the
                // only witness.
                retryQueue.append(PendingChunkRetry(
                    chunk: chunk,
                    attempts: retryAttempt + 1,
                    maxAttempts: maxAttempts,
                    retryDelay: isModelWait ? chunkRetryDelaySeconds : max(2, chunkRetryDelaySeconds / 3),
                    nextAttemptAt: Date().addingTimeInterval(
                        isModelWait ? chunkRetryDelaySeconds : max(2, chunkRetryDelaySeconds / 3)
                    ),
                    lastError: error.localizedDescription
                ))
                FileHandle.standardError.write(Data(
                    "harc-client: chunk \(chunk.startMs)ms failed (attempt \(retryAttempt + 1)/\(maxAttempts)): \(error.localizedDescription)\n".utf8
                ))
            } else {
                // Out of retries: the hole becomes part of the record instead
                // of a silent absence. The master WAV still has the audio.
                failedRanges.append(FailedChunkRange(
                    startMs: chunk.startMs,
                    endMs: chunk.endMs,
                    reason: error.localizedDescription
                ))
                try? FileManager.default.removeItem(at: chunk.audioURL)
            }
            throw error
        }

        // Far-field guard: VAD tuned for near-field speech mangles a quiet
        // room. On a real field recording it kept 8% of the transcript —
        // four chunks returned empty and every other chunk lost 77–98% of
        // its text, all "successfully". So the trigger is sparseness, not
        // emptiness: if a chunk with audible energy yields implausibly
        // little text under VAD, run it once without VAD and keep whichever
        // result says more. Over-triggering is harmless — a genuinely quiet
        // minute returns the same text both ways and costs one extra pass;
        // true silence stays below the energy floor and is never retried.
        let vadChars = result.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let chunkMinutes = max(0.25, Double(chunk.endMs - chunk.startMs) / 60_000.0)
        if vadEnabled,
           Double(vadChars) < Self.suspiciouslySparseCharsPerMinute * chunkMinutes,
           Self.hasAudibleEnergy(chunk.audioURL) {
            FileHandle.standardError.write(Data(
                "harc-client: chunk \(chunk.startMs)ms sparse under VAD (\(vadChars) chars) — retrying without VAD\n".utf8
            ))
            if let unvadded = try? await client.transcribe(
                audioPath: chunk.audioURL.path, diarize: false, vad: false
            ), unvadded.text.trimmingCharacters(in: .whitespacesAndNewlines).count > vadChars {
                result = unvadded
            }
        }

        try? FileManager.default.removeItem(at: chunk.audioURL)
        let cleanedText = VocabularyReplacer.apply(result.text, using: vocabulary)
        let cr = ChunkResult(
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            text: cleanedText,
            words: result.words,
            speakers: [],   // Per-chunk diarization is intentionally empty.
            processingMs: result.processingMs
        )
        assembler.add(cr)
        let index = assembler.currentJoinedText.isEmpty ? 0 : (assembler.currentJoinedText.split(separator: " ").count)
        updatesContinuation.yield(TranscriptUpdate(
            chunkIndex: index,
            joinedTextSoFar: assembler.currentJoinedText
        ))
    }
}
