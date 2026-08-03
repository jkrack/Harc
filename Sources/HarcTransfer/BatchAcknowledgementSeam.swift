import Foundation
import HarcDomain
import HarcIdentity

/// Host-owned durable facts used to issue one exact background-batch ACK.
/// The immutable descriptor is the sole source of upload, device, batch-body,
/// and accepted-chunk bindings.
public struct BatchAcknowledgementClaims: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let batch: ImmutableAudioBatchDescriptor
    public let acknowledgementID: UUID
    public let durableAt: Date

    public init(
        hostTrust: RecordingHostTrustBinding,
        batch: ImmutableAudioBatchDescriptor,
        acknowledgementID: UUID,
        durableAt: Date
    ) throws {
        guard acknowledgementID != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgementID"
            )
        }
        try TransferValidation.requireFinite(
            durableAt,
            field: "BatchAcknowledgementClaims.durableAt"
        )
        guard durableAt.timeIntervalSince1970 > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.durableAt"
            )
        }

        self.hostTrust = hostTrust
        self.batch = batch
        self.acknowledgementID = acknowledgementID
        self.durableAt = durableAt
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// Authority-authenticated and descriptor-bound evidence for one successful
/// immutable background batch. This proves host staging durability only; it is
/// never a recording receipt and cannot authorize deletion of a local master.
public struct ValidatedBatchAcknowledgementEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let exactAcknowledgementObject: OpaqueExactObjectSlot
    public let batchID: AudioBatchID
    public let uploadID: UploadID
    public let ownerDeviceID: DeviceID
    public let exactBatchBodySHA256: ImmutableBatchSHA256
    public let durableChunks: [DurableChunkStatus]
    public let acknowledgementID: UUID
    public let durableAt: Date

    /// Package access keeps construction inside a signature-validating module.
    package init(
        hostTrust: RecordingHostTrustBinding,
        exactAcknowledgementObject: OpaqueExactObjectSlot,
        batch: ImmutableAudioBatchDescriptor,
        durableChunks: [DurableChunkStatus],
        acknowledgementID: UUID,
        durableAt: Date
    ) throws {
        guard exactAcknowledgementObject.kind == .audioBatchAckV1 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.kind"
            )
        }
        guard acknowledgementID != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgementID"
            )
        }
        try TransferValidation.requireFinite(
            durableAt,
            field: "ValidatedBatchAcknowledgementEvidence.durableAt"
        )
        guard durableAt.timeIntervalSince1970 > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.durableAt"
            )
        }

        let expected = batch.chunks.map {
            DurableChunkStatus(
                chunkIndex: $0.chunkIndex,
                chunkID: $0.chunkID,
                encodedSHA256: $0.encodedSHA256
            )
        }
        guard durableChunks == expected else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.acceptedChunks"
            )
        }

        self.hostTrust = hostTrust
        self.exactAcknowledgementObject = exactAcknowledgementObject
        batchID = batch.batchID
        uploadID = batch.uploadID
        ownerDeviceID = batch.ownerDeviceID
        exactBatchBodySHA256 = batch.exactBodySHA256
        self.durableChunks = durableChunks
        self.acknowledgementID = acknowledgementID
        self.durableAt = durableAt
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// Exact host-signing seam injected into HarcHost without adding protobuf or
/// transport ownership to the host application-service target.
public protocol BatchAcknowledgementIssuing: Sendable {
    func issueBatchAcknowledgement(
        claims: BatchAcknowledgementClaims,
        hostAuthoritySigner: any P256DigestSigner
    ) throws -> ValidatedBatchAcknowledgementEvidence
}

/// Client acceptance seam. Implementations must authenticate the authority
/// signature and compare every payload/header field with the immutable local
/// descriptor before returning evidence.
public protocol BatchAcknowledgementEvidenceValidating: Sendable {
    func validateBatchAcknowledgement(
        exactSignedAcknowledgementBytes: Data,
        batch: ImmutableAudioBatchDescriptor,
        hostTrust: RecordingHostTrustBinding
    ) throws -> ValidatedBatchAcknowledgementEvidence
}
