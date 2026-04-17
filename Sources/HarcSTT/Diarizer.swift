import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's DiarizerManager. Separate from Transcriber because
/// the diarizer model loads independently — the Daemon pre-loads this in a
/// background task and degrades gracefully to empty speaker segments if load fails.
///
/// API adaptations from best-guess spec:
/// - `initialize(models:)` used instead of `loadModels(_:)` (consuming parameter pattern)
/// - `performCompleteDiarization` is synchronous `throws`, not `async throws`
/// - `TimedSpeakerSegment.speakerId` is `String` (UUID-style), not `Int`;
///   mapped to stable `Int` via an insertion-order dictionary inside the actor
/// - `startTimeSeconds`/`endTimeSeconds` are `Float`, not `Double`
public actor Diarizer: DiarizeService {
    private var manager: DiarizerManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func loadModels() async throws {
        guard manager == nil else { return }
        let m = DiarizerManager(config: .default)
        let models = try await DiarizerModels.download()
        m.initialize(models: models)
        self.manager = m
    }

    public func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        guard let m = manager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let result = try m.performCompleteDiarization(samples)

        // Map speaker ID strings to stable sequential integers (insertion order).
        var speakerIndex: [String: Int] = [:]
        return result.segments.map { seg in
            let idx: Int
            if let existing = speakerIndex[seg.speakerId] {
                idx = existing
            } else {
                idx = speakerIndex.count
                speakerIndex[seg.speakerId] = idx
            }
            return SpeakerSegment(
                speaker: idx,
                startMs: Int(seg.startTimeSeconds * 1000),
                endMs: Int(seg.endTimeSeconds * 1000)
            )
        }
    }
}
