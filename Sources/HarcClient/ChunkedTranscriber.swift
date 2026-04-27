import Foundation
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
public actor ChunkedTranscriber {
    private let client: any TranscribingClient
    private let diarizer: (any DiarizingClient)?
    private let vadEnabled: Bool
    private let chunkDurationSeconds: Double
    private let pollIntervalSeconds: Double
    private let vocabulary: Vocabulary

    nonisolated(unsafe) private let assembler = TranscriptAssembler()
    private var chunker: WAVChunker?
    private var audioURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    public let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    public init(
        client: any TranscribingClient,
        diarizer: (any DiarizingClient)? = nil,
        vadEnabled: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0,
        vocabulary: Vocabulary = .empty
    ) {
        self.client = client
        self.diarizer = diarizer
        self.vadEnabled = vadEnabled
        self.chunkDurationSeconds = chunkDurationSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.vocabulary = vocabulary
        let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
        self.updates = stream
        self.updatesContinuation = cont
    }

    public func start(audioURL: URL) {
        self.audioURL = audioURL
        self.chunker = WAVChunker(audioURL: audioURL, chunkDurationSeconds: chunkDurationSeconds)
        self.pumpTask = Task.detached { [self] in await self.pump() }
    }

    /// Stops polling, processes any remaining tail chunk, runs the full-WAV
    /// diarize pass, and returns the assembled transcript + embeddings.
    public func finalize(startedAt: Date, endedAt: Date) async throws -> ChunkedTranscriberFinalize {
        stopped = true
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

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

    private func pump() async {
        guard let chunker else { return }
        while !Task.isCancelled, !stopped {
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

    private func processChunk(_ chunk: WAVChunker.Chunk) async throws {
        defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
        // Per-chunk diarization is OFF — labels come from the post-stop
        // full-WAV diarize call in `finalize`.
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: false, vad: vadEnabled)
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
