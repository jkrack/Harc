import HarcDomain

/// Local, read-only evidence about one committed recording. This value is not
/// repair authorization and cannot authorize receipt replay or client cleanup.
public struct HostReceiptBindingDiagnostic: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case verifiedCurrentBinding
        case verifiedMetadataDrift
        case notFound
        case blocked
    }

    public enum Stage: String, Sendable {
        case receiptState
        case publicationActivity
        case trustedPath
        case filesystemIdentity
        case canonicalAudio
        case manifestEvidence
        case receiptEvidence
        case snapshotRecheck
    }

    public enum AudioStep: String, Sendable {
        case open, captureIdentity, compareExpectedIdentity, layout, preReadBinding, rewind, header, pcmHash, postReadBinding
    }

    public enum IdentityChange: String, Sendable {
        case device, inode, owner, permissions, linkCount, byteCount, changeTime
    }

    public let canonicalRecordingID: CanonicalRecordingID
    public let outcome: Outcome
    public let completedStages: [Stage]
    public let failureStage: Stage?
    /// A bounded classification, never an error's associated path or payload.
    public let failureCode: String?
    public let identityChanges: [IdentityChange]
    public let audioFailureStep: AudioStep?
}
