import Foundation
import HarcDomain
import HarcIdentity
import HarcProtocolWire
import HarcTransfer

/// Receipt evidence whose construction is sealed to HarcProtocol's concrete
/// signature-and-binding validator. Other production modules can carry this
/// value, but cannot manufacture one from package-constructible domain
/// evidence and thereby reach the client deletion gate.
public struct HarcAuthenticatedRecordingReceiptV1: Equatable, Sendable {
    package let evidence: ValidatedRecordingReceiptEvidence

    /// `internal` is intentional: package access would allow any production
    /// target in this Swift package to fabricate a cleanup-authorizing value.
    init(evidence: ValidatedRecordingReceiptEvidence) {
        self.evidence = evidence
    }
}

/// Exact V1 manifest/receipt codec injected through HarcTransfer-owned
/// interfaces. It has no persistence or transport behavior.
public struct HarcRecordingEvidenceCodecV1: Sendable,
    RecordingManifestEvidenceValidating,
    RecordingReceiptIssuing,
    RecordingReceiptEvidenceValidating
{
    public init() {}

    public func validateRecordingManifest(
        exactSignedManifestBytes: Data,
        hostTrust: RecordingHostTrustBinding,
        producingDevicePublicKey: P256X963PublicKey
    ) throws -> ValidatedRecordingManifestEvidence {
        // This call verifies the outer signature before the registered payload
        // decoder is allowed to interpret protobuf bytes.
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            exactSignedManifestBytes,
            using: producingDevicePublicKey,
            purpose: .historicalEvidence
        )
        guard case .recordingManifest(let exactPayload) = authenticated.payload else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: authenticated.signedObject.header.messageType.rawValue,
                payloadType: authenticated.signedObject.header.payloadType.rawValue
            )
        }
        let value = exactPayload.message

        let libraryID = try value.libraryID.domainValue()
        guard libraryID == hostTrust.libraryID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "libraryID")
        }
        let authorityID = try value.hostAuthorityID.domainValue()
        guard authorityID == hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostAuthorityID")
        }
        let producingDeviceID = try value.producingDeviceID.domainValue()
        guard producingDeviceID == producingDevicePublicKey.deviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "producingDeviceID")
        }
        let originRecordingID = try value.originRecordingID.domainValue()
        guard originRecordingID.deviceID == producingDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }

        let canonicalFormat = try value.canonicalFormat.domainValue()
        let manifestEncoding = try value.encoding.domainValue()
        let finalizedCapture = try FinalizedCapture(
            producingDeviceID: producingDeviceID,
            originRecordingID: originRecordingID,
            captureStartedAt: try exactDate(
                fromUnixMilliseconds: value.captureStartedAtUnixMs,
                field: "recordingManifest.captureStartedAt"
            ),
            captureEndedAt: try exactDate(
                fromUnixMilliseconds: value.captureEndedAtUnixMs,
                field: "recordingManifest.captureEndedAt"
            ),
            captureStartedMonotonicNanoseconds: value.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds: value.captureEndedMonotonicNanoseconds,
            finalizationReason: try finalizationReason(value.finalizationReason),
            canonicalFormat: canonicalFormat,
            totalCanonicalFrames: value.totalCanonicalFrames,
            totalCanonicalBytes: value.totalCanonicalBytes,
            canonicalPCMSHA256: try CanonicalPCMHash(
                value.canonicalPcmSha256.validatedBytes(
                    field: "recordingManifest.canonicalPCMSHA256"
                )
            ),
            discontinuities: try value.discontinuities.map { try $0.domainValue() }
        )
        let chunkedCapture = try ChunkedFinalizedCapture(
            capture: finalizedCapture,
            chunks: try value.chunks.map { try $0.domainValue() }
        )
        guard chunkedCapture.encoding == manifestEncoding else {
            throw TransferValidationError.evidenceBindingMismatch(field: "encoding")
        }

        let signedObject = authenticated.signedObject
        return try ValidatedRecordingManifestEvidence(
            hostTrust: hostTrust,
            exactManifestObject: OpaqueExactObjectSlot(
                kind: .recordingManifestV1,
                exactBytes: signedObject.exactFramedBytes,
                objectSHA256: signedObject.objectID
            ),
            uploadID: try value.uploadID.domainValue(),
            producingDevicePublicKey: producingDevicePublicKey,
            originRecordingID: originRecordingID,
            uploadProfileSHA256: try UploadProfileSHA256(
                value.uploadProfileSha256.validatedBytes(
                    field: "recordingManifest.uploadProfileSHA256"
                )
            ),
            finalizedCapture: chunkedCapture
        )
    }

    public func issueRecordingReceipt(
        claims: RecordingReceiptClaims,
        hostAuthoritySigner: any P256DigestSigner
    ) throws -> OpaqueExactObjectSlot {
        let manifest = claims.validatedManifest
        let trust = manifest.hostTrust
        guard hostAuthoritySigner.publicKey == trust.hostAuthorityPublicKey else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "hostAuthoritySigner"
            )
        }
        let issuedAt = try exactUnixMilliseconds(
            claims.durableCommitTime,
            field: "recordingReceipt.issuedAt"
        )
        guard issuedAt > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "durableCommitTime")
        }

        var value = Harc_V1_RecordingReceiptV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.libraryID = Harc_V1_LibraryIDV1(trust.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(trust.hostAuthorityID)
        value.producingDeviceID = Harc_V1_DeviceIDV1(manifest.producingDeviceID)
        value.originRecordingID = Harc_V1_OriginRecordingIDV1(manifest.originRecordingID)
        value.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            claims.canonicalRecordingID
        )
        value.uploadID = Harc_V1_UploadIDV1(manifest.uploadID)
        value.signedManifestObjectSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: manifest.exactManifestObject.objectSHA256.rawBytes
        )
        value.canonicalPcmSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: manifest.canonicalPCMSHA256.rawBytes
        )
        value.totalCanonicalFrames = manifest.totalCanonicalFrames
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(manifest.canonicalFormat)
        value.canonicalRecordingRevision = claims.canonicalRevision.rawValue
        value.changeCursor = claims.changeCursor.rawValue
        value.issuedAtUnixMs = issuedAt
        value.processingState = .recordingProcessingStatePending
        value.receiptID = receiptID(claims.receiptID)

        let exactPayload = try HarcExactProtobufPayload(serializingOnce: value)
        let header = try HarcSignedEnvelopeV1(
            messageType: .recordingReceipt,
            libraryID: trust.libraryID,
            hostAuthorityID: trust.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: manifest.uploadID.rawValue,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingReceipt,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload.exactBytes)
        )
        let object = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: .v1,
                libraryID: trust.libraryID,
                hostAuthorityID: trust.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAt,
                operationID: manifest.uploadID.rawValue
            ),
            using: hostAuthoritySigner
        )
        return try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: object.exactFramedBytes,
            objectSHA256: object.objectID
        )
    }

    public func validateRecordingReceipt(
        exactSignedReceiptBytes: Data,
        validatedManifest: ValidatedRecordingManifestEvidence,
        hostTrust: RecordingHostTrustBinding
    ) throws -> ValidatedRecordingReceiptEvidence {
        guard hostTrust == validatedManifest.hostTrust else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostTrust")
        }
        // As with manifests, signature authentication occurs before protobuf
        // payload interpretation.
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            exactSignedReceiptBytes,
            using: hostTrust.hostAuthorityPublicKey,
            purpose: .historicalEvidence
        )
        guard case .recordingReceipt(let exactPayload) = authenticated.payload else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: authenticated.signedObject.header.messageType.rawValue,
                payloadType: authenticated.signedObject.header.payloadType.rawValue
            )
        }
        let value = exactPayload.message

        guard try value.libraryID.domainValue() == hostTrust.libraryID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "libraryID")
        }
        guard try value.hostAuthorityID.domainValue() == hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "hostAuthorityID")
        }
        guard try value.producingDeviceID.domainValue() == validatedManifest.producingDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "producingDeviceID")
        }
        let originRecordingID = try value.originRecordingID.domainValue()
        guard originRecordingID == validatedManifest.originRecordingID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "originRecordingID")
        }
        let uploadID = try value.uploadID.domainValue()
        guard uploadID == validatedManifest.uploadID else {
            throw TransferValidationError.evidenceBindingMismatch(field: "uploadID")
        }

        let manifestObjectSHA256 = try ExactObjectSHA256(
            value.signedManifestObjectSha256.validatedBytes(
                field: "recordingReceipt.signedManifestObjectSHA256"
            )
        )
        guard manifestObjectSHA256 == validatedManifest.exactManifestObject.objectSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "signedManifestObjectSHA256"
            )
        }
        let canonicalPCMSHA256 = try CanonicalPCMHash(
            value.canonicalPcmSha256.validatedBytes(
                field: "recordingReceipt.canonicalPCMSHA256"
            )
        )
        guard canonicalPCMSHA256 == validatedManifest.canonicalPCMSHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalPCMSHA256")
        }
        guard value.totalCanonicalFrames == validatedManifest.totalCanonicalFrames else {
            throw TransferValidationError.evidenceBindingMismatch(field: "totalCanonicalFrames")
        }
        let canonicalFormat = try value.canonicalFormat.domainValue()
        guard canonicalFormat == validatedManifest.canonicalFormat else {
            throw TransferValidationError.evidenceBindingMismatch(field: "canonicalFormat")
        }
        guard value.processingState == .recordingProcessingStatePending else {
            throw TransferValidationError.evidenceBindingMismatch(field: "processingState")
        }

        let canonicalRecordingID = try value.canonicalRecordingID.domainValue()
        guard canonicalRecordingID.rawValue != HarcSignedEnvelopeV1.zeroUUID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "canonicalRecordingID"
            )
        }
        let canonicalRevision = try EntityRevision(value.canonicalRecordingRevision)
        guard value.changeCursor > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "changeCursor")
        }
        let receiptUUID = try nonzeroUUID(
            value.receiptID.value,
            field: "recordingReceipt.receiptID"
        )
        guard value.issuedAtUnixMs > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(field: "durableCommitTime")
        }
        let durableCommitTime = try exactDate(
            fromUnixMilliseconds: value.issuedAtUnixMs,
            field: "recordingReceipt.issuedAt"
        )

        let signedObject = authenticated.signedObject
        return try ValidatedRecordingReceiptEvidence(
            hostTrust: hostTrust,
            exactReceiptObject: OpaqueExactObjectSlot(
                kind: .recordingReceiptV1,
                exactBytes: signedObject.exactFramedBytes,
                objectSHA256: signedObject.objectID
            ),
            validatedManifest: validatedManifest,
            uploadID: uploadID,
            originRecordingID: originRecordingID,
            signedManifestObjectSHA256: manifestObjectSHA256,
            canonicalPCMSHA256: canonicalPCMSHA256,
            totalCanonicalFrames: value.totalCanonicalFrames,
            canonicalFormat: canonicalFormat,
            canonicalRecordingID: canonicalRecordingID,
            canonicalRevision: canonicalRevision,
            changeCursor: ChangeCursor(value.changeCursor),
            receiptID: receiptUUID,
            durableCommitTime: durableCommitTime,
            processingState: .pending
        )
    }

    /// Performs full receipt framing, registered-payload, host-signature,
    /// manifest, trust, and canonical-audio validation, then seals the result
    /// for persistence APIs that can authorize local cleanup.
    public func authenticateRecordingReceipt(
        exactSignedReceiptBytes: Data,
        validatedManifest: ValidatedRecordingManifestEvidence,
        hostTrust: RecordingHostTrustBinding
    ) throws -> HarcAuthenticatedRecordingReceiptV1 {
        HarcAuthenticatedRecordingReceiptV1(
            evidence: try validateRecordingReceipt(
                exactSignedReceiptBytes: exactSignedReceiptBytes,
                validatedManifest: validatedManifest,
                hostTrust: hostTrust
            )
        )
    }
}

private func finalizationReason(
    _ value: Harc_V1_CaptureFinalizationReasonV1
) throws -> CaptureFinalizationReason {
    switch value {
    case .captureFinalizationReasonUserStopped: .userStopped
    case .captureFinalizationReasonSystemEnded: .systemEnded
    case .captureFinalizationReasonRecoveredDurablePrefix: .recoveredDurablePrefix
    case .captureFinalizationReasonStorageExhausted: .storageExhausted
    case .captureFinalizationReasonWriterFailure: .writerFailure
    case .captureFinalizationReasonUnspecified, .UNRECOGNIZED:
        throw HarcProtobufConversionError.unsupportedEnum(
            field: "recordingManifest.finalizationReason",
            rawValue: value.rawValue
        )
    }
}

private func receiptID(_ value: UUID) -> Harc_V1_ReceiptIDV1 {
    var result = Harc_V1_ReceiptIDV1()
    result.value = uuidBytes(value)
    return result
}

private func uuidBytes(_ value: UUID) -> Data {
    withUnsafeBytes(of: value.uuid) { Data($0) }
}

private func nonzeroUUID(_ bytes: Data, field: String) throws -> UUID {
    guard bytes.count == 16 else {
        throw HarcProtobufConversionError.invalidLength(
            field: field,
            expected: 16,
            actual: bytes.count
        )
    }
    let value = [UInt8](bytes)
    let uuid = UUID(uuid: (
        value[0], value[1], value[2], value[3],
        value[4], value[5], value[6], value[7],
        value[8], value[9], value[10], value[11],
        value[12], value[13], value[14], value[15]
    ))
    guard uuid != HarcSignedEnvelopeV1.zeroUUID else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
    return uuid
}

private let maximumExactlyRepresentableUnixMilliseconds: UInt64 = 9_007_199_254_740_991

private func exactUnixMilliseconds(_ value: Date, field: String) throws -> UInt64 {
    let seconds = value.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0 else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite,
          milliseconds <= Double(maximumExactlyRepresentableUnixMilliseconds) else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let rounded = milliseconds.rounded()
    guard let result = UInt64(exactly: rounded),
          Date(timeIntervalSince1970: Double(result) / 1_000) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return result
}

private func exactDate(fromUnixMilliseconds value: UInt64, field: String) throws -> Date {
    guard value <= maximumExactlyRepresentableUnixMilliseconds else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let date = Date(timeIntervalSince1970: Double(value) / 1_000)
    guard try exactUnixMilliseconds(date, field: field) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return date
}
