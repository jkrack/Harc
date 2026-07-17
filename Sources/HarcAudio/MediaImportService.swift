import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import HarcClient
import HarcCore

/// Errors surfaced by media import. All user-facing via `errorDescription`.
public enum MediaImportError: LocalizedError, Equatable {
    case unsupportedType(String)
    case drmProtected
    case noAudioTrack
    case conversionFailed(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return "\(ext.isEmpty ? "This file" : ".\(ext)") is not a supported audio or video type."
        case .drmProtected:
            return "This file is copy-protected (DRM) and its audio cannot be read."
        case .noAudioTrack:
            return "This file has no audio track."
        case .conversionFailed(let detail):
            return "Could not read the file's audio: \(detail)"
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}

/// Progress ticks emitted during an import. `fraction` is 0…1 within the
/// whole import (conversion is weighted 0–0.3, transcription 0.3–0.95,
/// diarize/finalize 0.95–1.0) so a single progress bar reads sensibly.
public struct MediaImportProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case converting = "Converting"
        case transcribing = "Transcribing"
        case finalizing = "Finalizing"
    }

    public let phase: Phase
    public let fraction: Double

    public init(phase: Phase, fraction: Double) {
        self.phase = phase
        self.fraction = min(1, max(0, fraction))
    }
}

/// Result of a completed import — the standard `RecordingResult` (so the
/// post-stop ingest path is shared with live recordings) plus import metadata.
public struct MediaImportResult: Sendable {
    public let recording: RecordingResult
    /// Original source filename without extension — used as the library title.
    public let originalTitle: String
    public let durationSeconds: Double

    public init(recording: RecordingResult, originalTitle: String, durationSeconds: Double) {
        self.recording = recording
        self.originalTitle = originalTitle
        self.durationSeconds = durationSeconds
    }
}

/// Imports an existing audio/video file: extracts + normalizes the audio to
/// the app's 16 kHz mono WAV, transcribes it through the same chunked path a
/// live recording uses (full-WAV diarize at the end), and finalizes into the
/// standard destination hierarchy with `.txt`/`.json` siblings.
///
/// One instance per import. Mirrors `RecordingSession`'s finalize shape so
/// callers can reuse the existing post-stop ingest.
public actor MediaImportService {
    public struct Options: Sendable {
        public var diarize: Bool
        public var vadEnabled: Bool
        public var chunkDurationSeconds: Double
        public var vocabulary: Vocabulary

        public init(
            diarize: Bool = true,
            vadEnabled: Bool = true,
            chunkDurationSeconds: Double = 60.0,
            vocabulary: Vocabulary = .empty
        ) {
            self.diarize = diarize
            self.vadEnabled = vadEnabled
            self.chunkDurationSeconds = chunkDurationSeconds
            self.vocabulary = vocabulary
        }
    }

    public static let supportedAudioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac",
    ]
    public static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static var supportedExtensions: Set<String> {
        supportedAudioExtensions.union(supportedVideoExtensions)
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private let client: any TranscribingClient
    private let diarizer: (any DiarizingClient)?
    private let destination: RecordingDestination

    public init(
        client: any TranscribingClient,
        diarizer: (any DiarizingClient)?,
        destination: RecordingDestination
    ) {
        self.client = client
        self.diarizer = diarizer
        self.destination = destination
    }

    /// Run the full import. `importedAt` names the destination file
    /// (`YYYY/YYYY-MM-DD/HH-mm-ss.wav`); the original filename travels back
    /// as `originalTitle` for the library row.
    public func importFile(
        source: URL,
        importedAt: Date = Date(),
        options: Options = Options(),
        progress: @escaping @Sendable (MediaImportProgress) -> Void = { _ in }
    ) async throws -> MediaImportResult {
        let ext = source.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw MediaImportError.unsupportedType(ext)
        }

        // 1. Convert / extract the audio track to a cache WAV.
        progress(MediaImportProgress(phase: .converting, fraction: 0))
        let cacheURL = RecordingDestination.cachePath()
        let durationSeconds: Double
        do {
            durationSeconds = try await convertToCacheWAV(
                source: source,
                cacheURL: cacheURL
            ) { convertFraction in
                progress(MediaImportProgress(phase: .converting, fraction: convertFraction * 0.3))
            }
        } catch {
            try? FileManager.default.removeItem(at: cacheURL)
            throw error
        }

        // 2. Transcribe the complete WAV through the same chunked path a live
        // recording uses (per-chunk transcribe, full-WAV diarize at the end).
        let transcribed: (transcript: SessionTranscript, embeddings: [SpeakerEmbeddingRow], diarizeError: String?)
        do {
            transcribed = try await transcribe(
                cacheURL: cacheURL,
                importedAt: importedAt,
                durationSeconds: durationSeconds,
                options: options
            ) { transcribeFraction in
                progress(MediaImportProgress(phase: .transcribing, fraction: 0.3 + transcribeFraction * 0.65))
            }
        } catch {
            try? FileManager.default.removeItem(at: cacheURL)
            throw error
        }

        // 3. Finalize into the destination hierarchy — same shape as
        // RecordingSession.stop(): atomic move, then siblings next to the WAV.
        // Last cancellation point — past here the import completes.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: cacheURL)
            throw CancellationError()
        }
        progress(MediaImportProgress(phase: .finalizing, fraction: 0.96))
        let wavURL = try destination.publicPath(for: importedAt)
        try RecordingDestination.atomicMove(from: cacheURL, to: wavURL)

        var txtURL: URL? = nil
        var jsonURL: URL? = nil
        var transcript = transcribed.transcript
        transcript.audioPath = wavURL.path
        do {
            try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)
            let stem = wavURL.deletingPathExtension().lastPathComponent
            let parent = wavURL.deletingLastPathComponent()
            txtURL = parent.appendingPathComponent("\(stem).txt")
            jsonURL = parent.appendingPathComponent("\(stem).json")
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: import sibling write failed: \(error.localizedDescription)\n".utf8
            ))
        }

        progress(MediaImportProgress(phase: .finalizing, fraction: 1))
        return MediaImportResult(
            recording: RecordingResult(
                wavURL: wavURL,
                txtURL: txtURL,
                jsonURL: jsonURL,
                speakerEmbeddings: transcribed.embeddings,
                diarizationError: transcribed.diarizeError
            ),
            originalTitle: source.deletingPathExtension().lastPathComponent,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Conversion

    /// Decode the source's audio track and write it as 16 kHz mono WAV at
    /// `cacheURL` via the same `AudioFileWriter` live recordings use.
    /// Returns the decoded duration in seconds.
    private func convertToCacheWAV(
        source: URL,
        cacheURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        let asset = AVURLAsset(url: source)

        let protected = (try? await asset.load(.hasProtectedContent)) ?? false
        if protected { throw MediaImportError.drmProtected }

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaImportError.conversionFailed(error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw MediaImportError.noAudioTrack }

        let assetDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaImportError.conversionFailed(error.localizedDescription)
        }

        // Decode + downmix + resample straight to the app's native format.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFileWriter.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else {
            throw MediaImportError.conversionFailed("reader cannot add audio output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaImportError.conversionFailed(
                reader.error?.localizedDescription ?? "could not start reading"
            )
        }

        let writer = try AudioFileWriter(url: cacheURL)
        var writtenFrames: Int = 0
        while let sample = output.copyNextSampleBuffer() {
            // Cooperative cancel: stop decoding promptly and release the
            // reader; the caller removes the partial cache WAV.
            if Task.isCancelled {
                reader.cancelReading()
                try? writer.close()
                throw CancellationError()
            }
            guard let buffer = Self.pcmBuffer(from: sample) else { continue }
            try writer.write(buffer)
            writtenFrames += Int(buffer.frameLength)
            if assetDuration > 0 {
                let seconds = Double(writtenFrames) / AudioFileWriter.targetSampleRate
                progress(min(1, seconds / assetDuration))
            }
        }
        try writer.close()

        if reader.status == .failed {
            throw MediaImportError.conversionFailed(
                reader.error?.localizedDescription ?? "decode failed"
            )
        }
        guard writtenFrames > 0 else { throw MediaImportError.noAudioTrack }
        return Double(writtenFrames) / AudioFileWriter.targetSampleRate
    }

    /// Int16-interleaved CMSampleBuffer → float32 mono AVAudioPCMBuffer in the
    /// writer's target format (same Int16→Float32 mapping as WAVChunker).
    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let frameCount = byteCount / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return nil }

        var raw = Data(count: byteCount)
        let copyStatus = raw.withUnsafeMutableBytes { ptr -> OSStatus in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: ptr.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        guard let out = AVAudioPCMBuffer(
            pcmFormat: AudioMixer.targetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        out.frameLength = AVAudioFrameCount(frameCount)
        let channel = out.floatChannelData![0]
        raw.withUnsafeBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                channel[i] = Float(samples[i]) / 32767.0
            }
        }
        return out
    }

    // MARK: - Transcription

    /// Chunk the complete WAV and transcribe sequentially — the import
    /// equivalent of ChunkedTranscriber's pump, but with deterministic
    /// progress (the file size is known up front). Full-WAV diarize at the
    /// end mirrors the live-recording finalize.
    private func transcribe(
        cacheURL: URL,
        importedAt: Date,
        durationSeconds: Double,
        options: Options,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (transcript: SessionTranscript, embeddings: [SpeakerEmbeddingRow], diarizeError: String?) {
        let chunker = WAVChunker(
            audioURL: cacheURL,
            chunkDurationSeconds: options.chunkDurationSeconds
        )
        let assembler = TranscriptAssembler()
        let totalChunks = max(1, Int(ceil(durationSeconds / options.chunkDurationSeconds)))
        var processed = 0
        var failures = 0

        // One chunk at a time: slice → transcribe → delete temp, so a long
        // file never accumulates a directory of chunk WAVs.
        var reachedTail = false
        while !reachedTail {
            // Cooperative cancel between chunks — the caller cleans up the
            // cache WAV; per-chunk temps are removed by transcribeChunk.
            try Task.checkCancellation()
            let chunk: WAVChunker.Chunk?
            if let next = try await chunker.nextChunk() {
                chunk = next
            } else {
                chunk = try await chunker.flush()
                reachedTail = true
            }
            guard let chunk else { break }

            // Per-chunk diarization off — labels come from the full-WAV pass.
            if let result = await Self.transcribeChunk(
                chunk, client: client, vadEnabled: options.vadEnabled
            ) {
                assembler.add(ChunkResult(
                    startMs: chunk.startMs,
                    endMs: chunk.endMs,
                    text: VocabularyReplacer.apply(result.text, using: options.vocabulary),
                    words: result.words,
                    speakers: [],
                    processingMs: result.processingMs
                ))
            } else {
                failures += 1
            }
            processed += 1
            progress(Double(processed) / Double(totalChunks))
        }

        guard processed > 0, failures < processed else {
            throw MediaImportError.transcriptionFailed(
                processed == 0 ? "file contained no audio to transcribe"
                               : "every chunk failed to transcribe"
            )
        }

        var transcript = assembler.finalize(
            startedAt: importedAt,
            endedAt: importedAt.addingTimeInterval(durationSeconds),
            audioPath: cacheURL.path
        )
        transcript.joinedText = VocabularyReplacer.apply(
            transcript.joinedText, using: options.vocabulary
        )

        var embeddings: [SpeakerEmbeddingRow] = []
        var diarizeError: String? = nil
        if let diarizer {
            do {
                let result = try await diarizer.diarize(audioPath: cacheURL.path)
                transcript.speakers = result.segments
                embeddings = result.speakers
            } catch {
                diarizeError = error.localizedDescription
                FileHandle.standardError.write(Data(
                    "harc-audio: import diarize failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return (transcript, embeddings, diarizeError)
    }

    /// Transcribe one chunk; nil on failure (logged). Deletes the temp chunk
    /// file either way.
    private static func transcribeChunk(
        _ chunk: WAVChunker.Chunk,
        client: any TranscribingClient,
        vadEnabled: Bool
    ) async -> TranscribeResult? {
        defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
        do {
            return try await client.transcribe(
                audioPath: chunk.audioURL.path,
                diarize: false,
                vad: vadEnabled
            )
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: import chunk failed: \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
    }
}
