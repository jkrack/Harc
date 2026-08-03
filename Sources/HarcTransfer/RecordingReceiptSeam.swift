import Foundation
import HarcDomain
import HarcIdentity

/// Host-owned durable publication facts used to mint the one V1 audio-safety
/// receipt. All recording-origin and canonical-audio fields are derived from
/// an authenticated exact manifest rather than repeated caller input.
public struct RecordingReceiptClaims: Equatable, Hashable, Sendable {
    public let validatedManifest: ValidatedRecordingManifestEvidence
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalRevision: EntityRevision
    public let changeCursor: ChangeCursor
    public let receiptID: UUID
    public let durableCommitTime: Date

    public init(
        validatedManifest: ValidatedRecordingManifestEvidence,
        canonicalRecordingID: CanonicalRecordingID,
        canonicalRevision: EntityRevision,
        changeCursor: ChangeCursor,
        receiptID: UUID,
        durableCommitTime: Date
    ) throws {
        guard canonicalRecordingID.rawValue != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "canonicalRecordingID"
            )
        }
        guard changeCursor.rawValue > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "changeCursor")
        }
        guard receiptID != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "receiptID")
        }
        try TransferValidation.requireFinite(
            durableCommitTime,
            field: "RecordingReceiptClaims.durableCommitTime"
        )
        guard durableCommitTime.timeIntervalSince1970 > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "durableCommitTime"
            )
        }

        self.validatedManifest = validatedManifest
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalRevision = canonicalRevision
        self.changeCursor = changeCursor
        self.receiptID = receiptID
        self.durableCommitTime = durableCommitTime
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// Injection boundary used by HarcHost without importing HarcProtocol.
/// Implementations authenticate the exact device-signed object before
/// interpreting its protobuf payload.
public protocol RecordingManifestEvidenceValidating: Sendable {
    func validateRecordingManifest(
        exactSignedManifestBytes: Data,
        hostTrust: RecordingHostTrustBinding,
        producingDevicePublicKey: P256X963PublicKey
    ) throws -> ValidatedRecordingManifestEvidence
}

/// Injection boundary for the exact host-signed durable publication receipt.
public protocol RecordingReceiptIssuing: Sendable {
    func issueRecordingReceipt(
        claims: RecordingReceiptClaims,
        hostAuthoritySigner: any P256DigestSigner
    ) throws -> OpaqueExactObjectSlot
}

/// Injection boundary used by a client before any receipt can authorize local
/// cleanup. Implementations authenticate against the pinned adopted host and
/// bind every mirrored receipt fact to the exact validated manifest.
public protocol RecordingReceiptEvidenceValidating: Sendable {
    func validateRecordingReceipt(
        exactSignedReceiptBytes: Data,
        validatedManifest: ValidatedRecordingManifestEvidence,
        hostTrust: RecordingHostTrustBinding
    ) throws -> ValidatedRecordingReceiptEvidence
}
