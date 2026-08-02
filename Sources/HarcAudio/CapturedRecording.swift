import Foundation
import HarcClient
import HarcCore
import HarcDomain

/// A recoverable, host-neutral capture produced before any publication choice.
///
/// `localMasterURL` remains the durable source of truth until a committer has
/// accepted it. Capture never assumes that the recording belongs in this
/// Mac's public library: a standalone committer may publish it locally, while
/// a client committer may retain it in an outbox for a paired host.
public struct CapturedRecording: Sendable {
    public let localMasterURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let transcript: SessionTranscript?
    public let speakerEmbeddings: [SpeakerEmbeddingRow]
    public let warnings: [CaptureWarning]
    public let discontinuities: [CaptureDiscontinuity]

    public init(
        localMasterURL: URL,
        startedAt: Date,
        endedAt: Date,
        transcript: SessionTranscript? = nil,
        speakerEmbeddings: [SpeakerEmbeddingRow] = [],
        warnings: [CaptureWarning] = [],
        discontinuities: [CaptureDiscontinuity] = []
    ) {
        self.localMasterURL = localMasterURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.speakerEmbeddings = speakerEmbeddings
        self.warnings = warnings
        self.discontinuities = discontinuities
    }
}

/// Non-fatal capture and post-stop processing conditions.
///
/// These are typed so committers and UI layers can react without parsing log
/// strings. The complete local master remains available for every warning.
public enum CaptureWarning: Sendable, Equatable {
    /// System capture failed after microphone capture had already begun. The
    /// saved master contains microphone audio only.
    case systemAudioUnavailable(message: String?)
    /// Optional transcription finalization failed. The saved master is intact.
    case transcriptionFailed(message: String)
    /// Transcript text completed, but the optional full-file diarization pass
    /// failed and can be retried from the saved master.
    case diarizationFailed(message: String)
}

extension CapturedRecording {
    /// Compatibility projection for the pre-seam UI's retry affordance.
    var diarizationError: String? {
        for warning in warnings {
            if case .diarizationFailed(let message) = warning {
                return message
            }
        }
        return nil
    }
}
