import Foundation
import Combine

/// Phase a recording moves through after the user hits stop:
///   .idle               (initial; not set on `current`)
///   .identifying        (full-WAV diarization in flight)
///   .done(speakerCount) (labels written; auto-collapses in UI ~1.5 s)
///   .failed(message)    (diarize failed; UI offers retry)
public enum DiarizationPhase: Equatable, Sendable {
    case idle
    case identifying(startedAt: Date)
    case done(speakerCount: Int)
    case failed(message: String)
}

/// MainActor-bound observable; only one recording is ever post-processing
/// at a time so a single optional pair `(recordingID, phase)` suffices.
///
/// Mutators are gated on the recording ID — a stale `succeed(recordingID:)`
/// for a recording that's already been superseded is a no-op. This avoids
/// race conditions where the user starts a new recording before the prior
/// one's post-stop diarize call returns.
@MainActor
public final class RecordingPostProcessingState: ObservableObject {
    @Published public private(set) var current: Entry?

    public struct Entry: Equatable, Sendable {
        public let recordingID: Int64
        public let phase: DiarizationPhase
    }

    public init() {}

    public func begin(recordingID: Int64) {
        current = Entry(
            recordingID: recordingID,
            phase: .identifying(startedAt: Date())
        )
    }

    public func succeed(recordingID: Int64, speakerCount: Int) {
        guard current?.recordingID == recordingID else { return }
        current = Entry(recordingID: recordingID, phase: .done(speakerCount: speakerCount))
    }

    public func fail(recordingID: Int64, message: String) {
        guard current?.recordingID == recordingID else { return }
        current = Entry(recordingID: recordingID, phase: .failed(message: message))
    }

    public func clear(recordingID: Int64) {
        guard current?.recordingID == recordingID else { return }
        current = nil
    }
}
