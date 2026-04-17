import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's ASR pipeline (Parakeet TDT v3) for CoreML inference on ANE/Metal.
///
/// Models auto-download from HuggingFace on first `loadModels()` to
/// `~/Library/Application Support/FluidAudio/Models/`. Keep one instance for the
/// lifetime of the daemon — loading is expensive (seconds) and the underlying
/// CoreML compiled model is not cheap to hold.
public actor Transcriber {
    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { asrManager != nil }

    public func loadModels() async throws {
        guard asrManager == nil else { return }
        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        try await manager.loadModels(models)
        self.asrManager = manager
    }

    public func transcribe(audioPath: String) async throws -> TranscribeResult {
        guard let manager = asrManager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let start = DispatchTime.now()
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples)
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let words: [Word] = (result.tokenTimings ?? []).map { t in
            Word(
                text: t.token,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],                       // Diarizer fills this in Task 6
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }
}
