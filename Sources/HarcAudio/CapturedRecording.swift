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
    public let integrity: CaptureIntegrityReport
    public let startedMonotonicNanoseconds: UInt64
    public let endedMonotonicNanoseconds: UInt64

    public init(
        localMasterURL: URL,
        startedAt: Date,
        endedAt: Date,
        transcript: SessionTranscript? = nil,
        speakerEmbeddings: [SpeakerEmbeddingRow] = [],
        warnings: [CaptureWarning] = [],
        discontinuities: [CaptureDiscontinuity] = [],
        integrity: CaptureIntegrityReport = .init(),
        startedMonotonicNanoseconds: UInt64 = 0,
        endedMonotonicNanoseconds: UInt64 = 0
    ) {
        self.localMasterURL = localMasterURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.speakerEmbeddings = speakerEmbeddings
        self.warnings = warnings
        self.discontinuities = discontinuities
        self.integrity = integrity
        self.startedMonotonicNanoseconds = startedMonotonicNanoseconds
        self.endedMonotonicNanoseconds = endedMonotonicNanoseconds
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

public extension CapturedRecording {
    /// Bind observations only when the committer establishes the producing
    /// installation identity. Empty frame ranges annotate omitted audio without
    /// manufacturing silence or claiming an exact lost-frame count.
    func boundDiscontinuities(to origin: OriginRecordingID, totalFrames: UInt64) throws -> [CaptureDiscontinuity] {
        guard discontinuities.allSatisfy({ $0.recordingID == origin }) else {
            throw DomainValidationError.invalidState(reason: "Capture discontinuities belong to another origin.")
        }
        let observed = try integrity.issues.map { issue in
            let reason: CaptureDiscontinuityReason
            switch issue.reason {
            case .bufferOverrun: reason = .bufferOverrun
            case .writerFailure: reason = .writerFailure
            case .conversionFailed, .sourceStopped, .drainTimedOut: reason = .interruptionBegan
            }
            let offset = min(issue.frameOffset, totalFrames)
            return try CaptureDiscontinuity(
                recordingID: origin, monotonicTimeNanoseconds: issue.monotonicNanoseconds,
                wallTime: issue.detectedAt, reason: reason,
                affectedFrames: CanonicalFrameRange(startFrame: offset, endFrameExclusive: offset),
                canonicalizationPolicy: .annotateGapWithoutInsertedSilence
            )
        }
        return (discontinuities + observed).sorted {
            if $0.monotonicTimeNanoseconds != $1.monotonicTimeNanoseconds {
                return $0.monotonicTimeNanoseconds < $1.monotonicTimeNanoseconds
            }
            return $0.wallTime < $1.wallTime
        }
    }
}
