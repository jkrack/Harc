import Foundation
import HarcDomain
import HarcIdentity

/// Registry tags for exact signed objects whose protobuf payload and signature
/// verification belong to PR 4/5. This is intentionally not a receipt or
/// manifest model.
public enum ExactObjectKind: String, Codable, CaseIterable, Sendable {
    case recordingManifestV1
    case recordingReceiptV1
    case audioBatchAckV1
}

/// Durable byte slot for an already framed object and its independently
/// validated Section 11 identity. Construction preserves bytes but does not
/// claim that a signature or payload has been verified.
public struct OpaqueExactObjectSlot: Codable, Equatable, Hashable, Sendable {
    public let kind: ExactObjectKind
    public let exactBytes: Data
    public let objectSHA256: ExactObjectSHA256

    public init(
        kind: ExactObjectKind,
        exactBytes: Data,
        objectSHA256: ExactObjectSHA256
    ) throws {
        guard !exactBytes.isEmpty else {
            throw TransferValidationError.emptyExactObject
        }
        self.kind = kind
        self.exactBytes = exactBytes
        self.objectSHA256 = objectSHA256
    }

    private enum CodingKeys: String, CodingKey { case kind, exactBytes, objectSHA256 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(ExactObjectKind.self, forKey: .kind),
                exactBytes: container.decode(Data.self, forKey: .exactBytes),
                objectSHA256: container.decode(ExactObjectSHA256.self, forKey: .objectSHA256)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid exact-object slot.")
        }
    }
}

/// The adopted authority tuple used while validating a host-bound signed
/// object. This is a binding value, not proof that any signed bytes were valid.
public struct RecordingHostTrustBinding: Codable, Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostAuthorityPublicKey: P256X963PublicKey
    public var hostAuthorityPublicKeyX963: Data { hostAuthorityPublicKey.rawBytes }

    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostAuthorityPublicKey: P256X963PublicKey
    ) throws {
        guard hostAuthorityPublicKey.hostAuthorityID == hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostAuthorityPublicKey")
        }
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
    }

    /// Raw-key construction seam for modules that depend on HarcTransfer but
    /// intentionally do not depend directly on HarcIdentity. This performs the
    /// same strict P-256 point parsing and derived-authority binding check as
    /// the typed initializer.
    public init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        hostAuthorityPublicKeyX963: Data
    ) throws {
        try self.init(
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            hostAuthorityPublicKey: P256X963PublicKey(hostAuthorityPublicKeyX963)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID, hostAuthorityID, hostAuthorityPublicKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                hostAuthorityID: container.decode(HostAuthorityID.self, forKey: .hostAuthorityID),
                hostAuthorityPublicKey: container.decode(P256X963PublicKey.self, forKey: .hostAuthorityPublicKey)
            )
        } catch {
            throw TransferValidation.decodingFailure(
                error,
                codingPath: decoder.codingPath,
                description: "Invalid recording host-trust binding."
            )
        }
    }
}

/// Evidence emitted only by the future PR 4 exact-object validator after it
/// has parsed without reserialization, verified the producing-device
/// signature, and mirrored every manifest field represented here. This type
/// deliberately performs no signature verification itself.
public struct ValidatedRecordingManifestEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let exactManifestObject: OpaqueExactObjectSlot
    public let uploadID: UploadID
    public let producingDevicePublicKey: P256X963PublicKey
    public let originRecordingID: OriginRecordingID
    public let uploadProfileSHA256: UploadProfileSHA256
    public let finalizedCapture: ChunkedFinalizedCapture

    public var producingDeviceID: DeviceID { producingDevicePublicKey.deviceID }
    public var canonicalPCMSHA256: CanonicalPCMHash {
        finalizedCapture.capture.canonicalPCMSHA256
    }
    public var totalCanonicalFrames: UInt64 {
        finalizedCapture.capture.totalCanonicalFrames
    }
    public var canonicalFormat: CanonicalPCMFormat {
        finalizedCapture.capture.canonicalFormat
    }

    /// Package access is the explicit PR 4 validator construction seam. Do not
    /// widen this initializer or add a public protocol-based substitute.
    package init(
        hostTrust: RecordingHostTrustBinding,
        exactManifestObject: OpaqueExactObjectSlot,
        uploadID: UploadID,
        producingDevicePublicKey: P256X963PublicKey,
        originRecordingID: OriginRecordingID,
        uploadProfileSHA256: UploadProfileSHA256,
        finalizedCapture: ChunkedFinalizedCapture
    ) throws {
        guard exactManifestObject.kind == .recordingManifestV1 else {
            throw TransferValidationError.wrongExactObjectKind(
                expected: .recordingManifestV1,
                actual: exactManifestObject.kind
            )
        }
        guard originRecordingID == finalizedCapture.capture.originRecordingID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }
        guard producingDevicePublicKey.deviceID == finalizedCapture.capture.producingDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "producingDeviceID")
        }

        self.hostTrust = hostTrust
        self.exactManifestObject = exactManifestObject
        self.uploadID = uploadID
        self.producingDevicePublicKey = producingDevicePublicKey
        self.originRecordingID = originRecordingID
        self.uploadProfileSHA256 = uploadProfileSHA256
        self.finalizedCapture = finalizedCapture
    }
}

/// Evidence emitted only by the future PR 5 receipt validator after it has
/// verified the host signature and matched the exact receipt payload to a
/// locally validated manifest and adopted authority. Its package initializer
/// makes that validator the construction boundary without pretending that
/// HarcTransfer can parse or verify the future protobuf object.
public struct ValidatedRecordingReceiptEvidence: Equatable, Hashable, Sendable {
    public let hostTrust: RecordingHostTrustBinding
    public let exactReceiptObject: OpaqueExactObjectSlot
    public let uploadID: UploadID
    public let originRecordingID: OriginRecordingID
    public let producingDeviceID: DeviceID
    public let exactManifestObject: OpaqueExactObjectSlot
    public let signedManifestObjectSHA256: ExactObjectSHA256
    public let uploadProfileSHA256: UploadProfileSHA256
    public let canonicalPCMSHA256: CanonicalPCMHash
    public let totalCanonicalFrames: UInt64
    public let canonicalFormat: CanonicalPCMFormat
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalRevision: EntityRevision
    public let changeCursor: ChangeCursor
    public let receiptID: UUID
    public let durableCommitTime: Date

    /// Package access is the explicit PR 5 validator construction seam. Every
    /// argument before the canonical result fields is mirrored against the
    /// already validated manifest so a receipt for another host, upload,
    /// origin, manifest, profile, or audio stream cannot become evidence.
    package init(
        hostTrust: RecordingHostTrustBinding,
        exactReceiptObject: OpaqueExactObjectSlot,
        validatedManifest: ValidatedRecordingManifestEvidence,
        uploadID: UploadID,
        originRecordingID: OriginRecordingID,
        signedManifestObjectSHA256: ExactObjectSHA256,
        canonicalPCMSHA256: CanonicalPCMHash,
        totalCanonicalFrames: UInt64,
        canonicalFormat: CanonicalPCMFormat,
        canonicalRecordingID: CanonicalRecordingID,
        canonicalRevision: EntityRevision,
        changeCursor: ChangeCursor,
        receiptID: UUID,
        durableCommitTime: Date
    ) throws {
        guard exactReceiptObject.kind == .recordingReceiptV1 else {
            throw TransferValidationError.wrongExactObjectKind(
                expected: .recordingReceiptV1,
                actual: exactReceiptObject.kind
            )
        }
        guard hostTrust == validatedManifest.hostTrust else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostTrust")
        }
        guard uploadID == validatedManifest.uploadID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadID")
        }
        guard originRecordingID == validatedManifest.originRecordingID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }
        guard signedManifestObjectSHA256 == validatedManifest.exactManifestObject.objectSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "signedManifestObjectSHA256")
        }
        guard canonicalPCMSHA256 == validatedManifest.canonicalPCMSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalPCMSHA256")
        }
        guard totalCanonicalFrames == validatedManifest.totalCanonicalFrames else {
            throw TransferValidationError.evidenceBindingMismatch(field: "totalCanonicalFrames")
        }
        guard canonicalFormat == validatedManifest.canonicalFormat else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalFormat")
        }
        guard canonicalRecordingID.rawValue != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalRecordingID")
        }
        guard changeCursor.rawValue > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "changeCursor")
        }
        guard receiptID != Self.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "receiptID")
        }
        try TransferValidation.requireFinite(
            durableCommitTime,
            field: "ValidatedRecordingReceiptEvidence.durableCommitTime"
        )

        self.hostTrust = hostTrust
        self.exactReceiptObject = exactReceiptObject
        self.uploadID = uploadID
        self.originRecordingID = originRecordingID
        self.producingDeviceID = originRecordingID.deviceID
        self.exactManifestObject = validatedManifest.exactManifestObject
        self.signedManifestObjectSHA256 = signedManifestObjectSHA256
        self.uploadProfileSHA256 = validatedManifest.uploadProfileSHA256
        self.canonicalPCMSHA256 = canonicalPCMSHA256
        self.totalCanonicalFrames = totalCanonicalFrames
        self.canonicalFormat = canonicalFormat
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
