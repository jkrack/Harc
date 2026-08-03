import Foundation
import HarcIdentity
import HarcProtocolWire
import HarcTransfer

/// Exact V1 background-batch acknowledgement codec. It is deliberately
/// transport-free: the HTTPS and gRPC adapters call the same issuer/validator.
public struct HarcBatchAcknowledgementCodecV1: Sendable,
    BatchAcknowledgementIssuing,
    BatchAcknowledgementEvidenceValidating
{
    public init() {}

    public func issueBatchAcknowledgement(
        claims: BatchAcknowledgementClaims,
        hostAuthoritySigner: any P256DigestSigner
    ) throws -> ValidatedBatchAcknowledgementEvidence {
        guard hostAuthoritySigner.publicKey == claims.hostTrust.hostAuthorityPublicKey else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.hostAuthoritySigner"
            )
        }
        let issuedAt = try batchAckExactUnixMilliseconds(
            claims.durableAt,
            field: "batchAcknowledgement.durableAt"
        )
        guard issuedAt > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.durableAt"
            )
        }

        var value = Harc_V1_BatchAckV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.libraryID = Harc_V1_LibraryIDV1(claims.hostTrust.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            claims.hostTrust.hostAuthorityID
        )
        value.deviceID = Harc_V1_DeviceIDV1(claims.batch.ownerDeviceID)
        value.uploadID = Harc_V1_UploadIDV1(claims.batch.uploadID)
        value.batchID = Harc_V1_AudioBatchIDV1(claims.batch.batchID)
        value.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: claims.batch.exactBodySHA256.rawBytes
        )
        value.acceptedChunks = try claims.batch.chunks.map { chunk in
            var accepted = Harc_V1_AcceptedBatchChunkV1()
            accepted.chunkIndex = chunk.chunkIndex
            accepted.encodedSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: chunk.encodedSHA256.rawBytes
            )
            return accepted
        }
        value.durableAtUnixMs = issuedAt
        value.ackID = Harc_V1_BatchAckIDV1(claims.acknowledgementID)
        value.issuedAtUnixMs = issuedAt

        let exactPayload = try HarcExactProtobufPayload(serializingOnce: value)
        let header = try HarcSignedEnvelopeV1(
            messageType: .batchAcknowledgement,
            libraryID: claims.hostTrust.libraryID,
            hostAuthorityID: claims.hostTrust.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: claims.batch.batchID.rawValue,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .batchAcknowledgement,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload.exactBytes)
        )
        let object = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: .v1,
                libraryID: claims.hostTrust.libraryID,
                hostAuthorityID: claims.hostTrust.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAt,
                operationID: claims.batch.batchID.rawValue
            ),
            using: hostAuthoritySigner
        )
        let exactObject = try OpaqueExactObjectSlot(
            kind: .audioBatchAckV1,
            exactBytes: object.exactFramedBytes,
            objectSHA256: object.objectID
        )
        return try ValidatedBatchAcknowledgementEvidence(
            hostTrust: claims.hostTrust,
            exactAcknowledgementObject: exactObject,
            batch: claims.batch,
            durableChunks: durableChunks(for: claims.batch),
            acknowledgementID: claims.acknowledgementID,
            durableAt: claims.durableAt
        )
    }

    public func validateBatchAcknowledgement(
        exactSignedAcknowledgementBytes: Data,
        batch: ImmutableAudioBatchDescriptor,
        hostTrust: RecordingHostTrustBinding
    ) throws -> ValidatedBatchAcknowledgementEvidence {
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            exactSignedAcknowledgementBytes,
            using: hostTrust.hostAuthorityPublicKey,
            purpose: .historicalEvidence
        )
        guard case .batchAcknowledgement(let exactPayload) = authenticated.payload else {
            throw HarcProtocolCodecError.unregisteredSignedObject(
                messageType: authenticated.signedObject.header.messageType.rawValue,
                payloadType: authenticated.signedObject.header.payloadType.rawValue
            )
        }
        let value = exactPayload.message

        guard try value.libraryID.domainValue() == hostTrust.libraryID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.libraryID"
            )
        }
        guard try value.hostAuthorityID.domainValue() == hostTrust.hostAuthorityID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.hostAuthorityID"
            )
        }
        guard try value.deviceID.domainValue() == batch.ownerDeviceID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.deviceID"
            )
        }
        guard try value.uploadID.domainValue() == batch.uploadID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.uploadID"
            )
        }
        guard try value.batchID.domainValue() == batch.batchID else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.batchID"
            )
        }
        let bodyHash = try ImmutableBatchSHA256(
            value.exactBatchBodySha256.validatedBytes(
                field: "batchAcknowledgement.exactBatchBodySHA256"
            )
        )
        guard bodyHash == batch.exactBodySHA256 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.exactBatchBodySHA256"
            )
        }

        let expectedDurableChunks = durableChunks(for: batch)
        guard value.acceptedChunks.count == expectedDurableChunks.count else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.acceptedChunks"
            )
        }
        for (accepted, expected) in zip(value.acceptedChunks, expectedDurableChunks) {
            guard accepted.chunkIndex == expected.chunkIndex,
                  try accepted.encodedSha256.validatedBytes(
                    field: "batchAcknowledgement.acceptedChunks.encodedSHA256"
                  ) == expected.encodedSHA256.rawBytes else {
                throw TransferValidationError.evidenceBindingMismatch(
                    field: "batchAcknowledgement.acceptedChunks"
                )
            }
        }

        guard value.issuedAtUnixMs == value.durableAtUnixMs,
              value.durableAtUnixMs > 0 else {
            throw TransferValidationError.evidenceBindingMismatch(
                field: "batchAcknowledgement.durableAt"
            )
        }
        let durableAt = try batchAckExactDate(
            fromUnixMilliseconds: value.durableAtUnixMs,
            field: "batchAcknowledgement.durableAt"
        )
        let acknowledgementID = try value.ackID.validatedUUID()
        let signedObject = authenticated.signedObject

        return try ValidatedBatchAcknowledgementEvidence(
            hostTrust: hostTrust,
            exactAcknowledgementObject: OpaqueExactObjectSlot(
                kind: .audioBatchAckV1,
                exactBytes: signedObject.exactFramedBytes,
                objectSHA256: signedObject.objectID
            ),
            batch: batch,
            durableChunks: expectedDurableChunks,
            acknowledgementID: acknowledgementID,
            durableAt: durableAt
        )
    }

    private func durableChunks(
        for batch: ImmutableAudioBatchDescriptor
    ) -> [DurableChunkStatus] {
        batch.chunks.map {
            DurableChunkStatus(
                chunkIndex: $0.chunkIndex,
                chunkID: $0.chunkID,
                encodedSHA256: $0.encodedSHA256
            )
        }
    }
}

private let batchAckMaximumExactlyRepresentableUnixMilliseconds: UInt64 =
    9_007_199_254_740_991

private func batchAckExactUnixMilliseconds(
    _ value: Date,
    field: String
) throws -> UInt64 {
    let seconds = value.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0 else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite,
          milliseconds <= Double(batchAckMaximumExactlyRepresentableUnixMilliseconds) else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let rounded = milliseconds.rounded()
    guard let result = UInt64(exactly: rounded),
          Date(timeIntervalSince1970: Double(result) / 1_000) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return result
}

private func batchAckExactDate(
    fromUnixMilliseconds value: UInt64,
    field: String
) throws -> Date {
    guard value <= batchAckMaximumExactlyRepresentableUnixMilliseconds else {
        throw HarcProtobufConversionError.integerOutOfRange(field: field)
    }
    let date = Date(timeIntervalSince1970: Double(value) / 1_000)
    guard try batchAckExactUnixMilliseconds(date, field: field) == value else {
        throw HarcProtobufConversionError.lossyConversion(field: field)
    }
    return date
}
