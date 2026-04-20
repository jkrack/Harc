import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's `VadManager` with Harc-specific defaults. Loads the
/// Silero VAD CoreML model once and keeps it resident; owns the
/// `VadSegmentationConfig` (hard-coded to `.default`). Provides a
/// compile-time "skip Parakeet if voiced duration too small" predicate
/// used by `Transcriber`.
public actor VADGate {
    private var manager: VadManager?
    private let segmentationConfig = VadSegmentationConfig.default

    /// Parakeet on clips shorter than this tends to return garbage or
    /// drop the audio; better to skip the pass entirely. Not configurable.
    public static let minVoicedSeconds: Double = 0.5

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Load the Silero VAD model. Safe to call repeatedly; no-op when loaded.
    public func loadModel() async throws {
        guard manager == nil else { return }
        self.manager = try await VadManager()
    }

    /// Segment `samples` (16 kHz mono Float32) into speech regions.
    public func segments(in samples: [Float]) async throws -> [VadSegment] {
        guard let manager else { throw DaemonError.modelNotLoaded }
        return try await manager.segmentSpeech(samples, config: segmentationConfig)
    }

    /// True iff the segments cover at least `minVoicedSeconds` of audio.
    public static func hasMinimumVoicedDuration(_ segments: [VadSegment]) -> Bool {
        let total = segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        return total >= minVoicedSeconds
    }
}
