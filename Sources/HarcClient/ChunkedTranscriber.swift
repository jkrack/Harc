import Foundation
import HarcCore

/// Protocol boundary for testing — any client that can transcribe a WAV path.
public protocol TranscribingClient: Sendable {
    func transcribe(audioPath: String, diarize: Bool) async throws -> TranscribeResult
}

extension HarcSTTClient: TranscribingClient {}

/// Drives a WAVChunker, dispatches each chunk to a TranscribingClient,
/// assembles a session transcript. Exposes an AsyncStream for live UI updates.
public actor ChunkedTranscriber {
    private let client: any TranscribingClient
    private let diarize: Bool
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
        diarize: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0,
        vocabulary: Vocabulary = .empty
    ) {
        self.client = client
        self.diarize = diarize
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

    /// Stops polling, processes any remaining tail chunk, and returns the final assembly.
    public func finalize(startedAt: Date, endedAt: Date) async throws -> SessionTranscript {
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
                // Best-effort: a failed tail chunk shouldn't lose the earlier work.
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
        // Second pass on the joined text — catches rules whose match spans a chunk boundary.
        assembled.joinedText = VocabularyReplacer.apply(assembled.joinedText, using: vocabulary)
        return assembled
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
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: diarize)
        let cleanedText = VocabularyReplacer.apply(result.text, using: vocabulary)
        let cr = ChunkResult(
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            text: cleanedText,
            words: result.words,
            speakers: result.speakers,
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
