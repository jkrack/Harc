import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's ASR pipeline (Parakeet TDT v3) for CoreML inference on
/// ANE/Metal, with an optional VAD pre-filter that strips silent regions and
/// remaps Parakeet's timestamps back to the original chunk timeline.
public actor Transcriber {
    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()
    private let vadGate: VADGate
    /// Sample rate the VAD / stitcher / remapper operate at. Matches what
    /// AudioConverter.resampleAudioFile emits by default. Making this
    /// explicit prevents silent misbehaviour if the pipeline's audio
    /// format ever changes.
    private static let sampleRate: Int = 16000

    public init(vadGate: VADGate = VADGate()) {
        self.vadGate = vadGate
    }

    public var isLoaded: Bool { asrManager != nil }

    public func loadModels() async throws {
        guard asrManager == nil else { return }
        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        try await manager.loadModels(models)
        self.asrManager = manager
        // VAD is an optimisation — its failure must never block ASR load.
        do {
            try await vadGate.loadModel()
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: VAD model load failed (\(error.localizedDescription)) — transcription will run without VAD\n".utf8
            ))
        }
    }

    public func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult {
        guard let manager = asrManager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        if !vad {
            return try await runParakeet(on: samples, with: manager, regions: nil)
        }

        let vadStart = DispatchTime.now()
        let segments: [VadSegment]
        do {
            segments = try await vadGate.segments(in: samples)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: VAD failed (\(error.localizedDescription)) — falling back to full chunk transcription for \(audioPath)\n".utf8
            ))
            return try await runParakeet(on: samples, with: manager, regions: nil)
        }
        let vadMs = Int((DispatchTime.now().uptimeNanoseconds - vadStart.uptimeNanoseconds) / 1_000_000)

        guard VADGate.hasMinimumVoicedDuration(segments) else {
            return TranscribeResult(text: "", words: [], speakers: [], processingMs: vadMs)
        }

        let stitch = VoicedStitcher.stitch(
            samples: samples,
            segments: segments,
            sampleRate: Self.sampleRate
        )
        return try await runParakeet(on: stitch.compactSamples, with: manager, regions: stitch.regions)
    }

    private func runParakeet(
        on samples: [Float],
        with manager: AsrManager,
        regions: [VoicedRegion]?
    ) async throws -> TranscribeResult {
        let start = DispatchTime.now()
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples)
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let compactWords: [Word] = (result.tokenTimings ?? []).map { t in
            Word(
                text: t.token,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }
        let words = regions.map {
            VADTimestampRemapper.remap(
                words: compactWords,
                regions: $0,
                sampleRate: Self.sampleRate
            )
        } ?? compactWords

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }
}
