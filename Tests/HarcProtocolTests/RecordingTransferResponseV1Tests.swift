import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Recording transfer response V1 validation")
struct RecordingTransferResponseV1Tests {
    @Test("responses remain bound to upload, profile, and generation")
    func requestBindingsRejectDrift() throws {
        let fixture = try ResponseFixture()

        let declarationRequest = try fixture.validatedDeclareRequest()
        var declaration = fixture.declareResponse()
        _ = try HarcValidatedDeclareChunksResponseV1(
            declaration,
            expectedRequest: declarationRequest
        )

        declaration.uploadID = Harc_V1_UploadIDV1(fixture.otherUploadID)
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.uploadID"
        )) {
            try HarcValidatedDeclareChunksResponseV1(
                declaration,
                expectedRequest: declarationRequest
            )
        }

        declaration = fixture.declareResponse()
        declaration.uploadGeneration += 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.uploadGeneration"
        )) {
            try HarcValidatedDeclareChunksResponseV1(
                declaration,
                expectedRequest: declarationRequest
            )
        }

        let reconcileRequest = try fixture.validatedReconcileRequest()
        var reconciliation = try fixture.reconciliationResponse()
        _ = try HarcValidatedReconcileUploadResponseV1(
            reconciliation,
            expectedRequest: reconcileRequest
        )
        reconciliation.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0xee, count: 32)
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "reconcileUploadResponse.uploadProfileSHA256"
        )) {
            try HarcValidatedReconcileUploadResponseV1(
                reconciliation,
                expectedRequest: reconcileRequest
            )
        }

        let beginRequest = try fixture.validatedBeginRequest()
        var begin = try fixture.beginResponse()
        _ = try HarcValidatedBeginUploadResponseV1(
            begin,
            expectedRequest: beginRequest
        )
        begin.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0xef, count: 32)
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "beginUploadResponse.uploadProfileSHA256"
        )) {
            try HarcValidatedBeginUploadResponseV1(
                begin,
                expectedRequest: beginRequest
            )
        }
    }

    @Test("reconciliation requires authoritative ordered Begin timestamps")
    func authoritativeBeginTimestamps() throws {
        let fixture = try ResponseFixture()
        var response = try fixture.reconciliationResponse()
        response.firstBeganAtUnixMs = 0
        #expect(throws: HarcProtobufConversionError.integerOutOfRange(
            field: "reconcileUploadResponse.firstBeganAt"
        )) {
            try HarcValidatedReconcileUploadResponseV1(response)
        }

        response = try fixture.reconciliationResponse()
        response.generationBeganAtUnixMs = response.generationExpiresAtUnixMs
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "reconcileUploadResponse.state"
        )) {
            try HarcValidatedReconcileUploadResponseV1(response)
        }
    }

    @Test("already committed replay preserves the original upload receipt")
    func alreadyCommittedReplayBinding() throws {
        let fixture = try ResponseFixture()
        let request = try fixture.validatedBeginRequest()
        let priorReceipt = try fixture.receiptObject(
            uploadID: fixture.otherUploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: fixture.manifestObject.objectID
        )
        var response = try fixture.beginResponse()
        response.disposition = .beginUploadDispositionAlreadyCommitted
        response.uploadGeneration = 0
        response.generationExpiresAtUnixMs = 0
        response.clearReconciliation()
        response.existingCanonicalRecordingID =
            Harc_V1_CanonicalRecordingIDV1(fixture.canonicalRecordingID)
        response.exactExistingReceipt = exactCarrier(
            priorReceipt.exactFramedBytes
        )

        let validated = try HarcValidatedBeginUploadResponseV1(
            response,
            expectedRequest: request
        )
        #expect(validated.uploadID == fixture.uploadID)
        #expect(validated.existingReceipt?.uploadID == fixture.otherUploadID)

        let wrongLibrary = LibraryID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000099")!
        )
        let mismatchedReceipt = try fixture.receiptObject(
            uploadID: fixture.otherUploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: fixture.manifestObject.objectID,
            libraryID: wrongLibrary
        )
        response.exactExistingReceipt = exactCarrier(
            mismatchedReceipt.exactFramedBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "beginUploadResponse.existingReceipt.requestBinding"
        )) {
            try HarcValidatedBeginUploadResponseV1(
                response,
                expectedRequest: request
            )
        }
    }

    @Test("blocked declaration replay binds the durable conflict to the origin")
    func conflictReplayBinding() throws {
        let fixture = try ResponseFixture()
        let request = try fixture.validatedDeclareRequest()
        let conflict = try ChunkDeclarationConflict(
            existing: fixture.descriptor,
            attempted: fixture.conflictingDescriptor
        )
        var response = fixture.declareResponse()
        response.disposition = .chunkDeclarationDispositionConflictBlocked
        response.clearFirstAppendedIndex()
        response.clearAppendedCount()
        response.conflict = try Harc_V1_ChunkDeclarationConflictV1(conflict)

        let validated = try HarcValidatedDeclareChunksResponseV1(
            response,
            expectedRequest: request
        )
        #expect(validated.disposition == .conflictBlocked(conflict))
    }

    @Test("chunk acknowledgements bind every immutable request field")
    func chunkAcknowledgementBinding() throws {
        let fixture = try ResponseFixture()
        let request = try fixture.validatedUploadRequest()
        var response = try fixture.uploadAcknowledgementResponse()
        let validated = try HarcValidatedUploadChunkResponseV1(
            response,
            expectedRequest: request
        )
        #expect(validated.result == .acknowledgement)
        #expect(validated.acknowledgement?.uploadID == fixture.uploadID)

        guard case .acknowledgement(var acknowledgement)? = response.result
        else {
            Issue.record("Expected acknowledgement")
            return
        }
        acknowledgement.uploadGeneration += 1
        response.result = .acknowledgement(acknowledgement)
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "uploadChunkResponse.acknowledgement.requestBinding"
        )) {
            try HarcValidatedUploadChunkResponseV1(
                response,
                expectedRequest: request
            )
        }

        response = try fixture.uploadAcknowledgementResponse()
        response.clearProtocol()
        #expect(throws: HarcProtobufConversionError.missingField(
            "uploadChunkResponse.protocol"
        )) {
            try HarcValidatedUploadChunkResponseV1(
                response,
                expectedRequest: request
            )
        }

        var rejected = Harc_V1_RejectedChunkV1()
        rejected.chunkIndex = fixture.descriptor.chunkIndex
        rejected.chunkID = Harc_V1_ChunkIDV1(fixture.descriptor.chunkID)
        rejected.reason = .rejectedChunkReasonUnspecified
        response = Harc_V1_UploadChunkResponseV1()
        response.protocol = HarcProtocolVersion.v1.protobufV1()
        response.result = .rejection(rejected)
        #expect(throws: HarcProtobufConversionError.unsupportedEnum(
            field: "rejectedChunk.reason",
            rawValue: 0
        )) {
            try HarcValidatedUploadChunkResponseV1(
                response,
                expectedRequest: request
            )
        }
    }

    @Test("dispositions and reconciliation evidence fail closed")
    func dispositionAndReconciliationConsistency() throws {
        let fixture = try ResponseFixture()

        var declaration = fixture.declareResponse()
        declaration.disposition = .chunkDeclarationDispositionExactReplay
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "declareChunksResponse.dispositionEvidence"
        )) {
            try HarcValidatedDeclareChunksResponseV1(declaration)
        }

        var begin = try fixture.beginResponse()
        begin.clearReconciliation()
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "beginUploadResponse.dispositionEvidence"
        )) {
            try HarcValidatedBeginUploadResponseV1(begin)
        }

        var reconciliation = try fixture.reconciliationResponse(
            declarations: fixture.twoDescriptors
        )
        var firstDurable = try Harc_V1_DurableChunkV1(
            DurableChunkStatus(
                chunkIndex: fixture.twoDescriptors[0].chunkIndex,
                chunkID: fixture.twoDescriptors[0].chunkID,
                encodedSHA256: fixture.twoDescriptors[0].encodedSHA256
            )
        )
        var secondDurable = try Harc_V1_DurableChunkV1(
            DurableChunkStatus(
                chunkIndex: fixture.twoDescriptors[1].chunkIndex,
                chunkID: fixture.twoDescriptors[1].chunkID,
                encodedSHA256: fixture.twoDescriptors[1].encodedSHA256
            )
        )
        swap(&firstDurable, &secondDurable)
        reconciliation.durableChunks = [firstDurable, secondDurable]
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "reconcileUploadResponse.state"
        )) {
            try HarcValidatedReconcileUploadResponseV1(reconciliation)
        }

        reconciliation = try fixture.reconciliationResponse()
        reconciliation.terminalReason = .uploadTerminalReasonCommitted
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "reconcileUploadResponse.state"
        )) {
            try HarcValidatedReconcileUploadResponseV1(reconciliation)
        }
    }

    @Test("receipt carriers preserve exact bytes and reject type or manifest drift")
    func exactReceiptValidation() throws {
        let fixture = try ResponseFixture()
        let commitRequest = try fixture.validatedCommitRequest()
        let receipt = try fixture.receiptObject(
            uploadID: fixture.uploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: fixture.manifestObject.objectID
        )
        var response = Harc_V1_CommitUploadResponseV1()
        response.protocol = HarcProtocolVersion.v1.protobufV1()
        response.disposition = .commitUploadDispositionCommitted
        response.exactSignedRecordingReceipt = exactCarrier(
            receipt.exactFramedBytes
        )
        let validated = try HarcValidatedCommitUploadResponseV1(
            response,
            expectedRequest: commitRequest
        )
        #expect(validated.receipt.exactBytes == receipt.exactFramedBytes)
        #expect(validated.receipt.objectSHA256 == receipt.objectID)

        let wrongManifestReceipt = try fixture.receiptObject(
            uploadID: fixture.uploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: try ExactObjectSHA256(
                Data(repeating: 0x99, count: 32)
            )
        )
        response.exactSignedRecordingReceipt = exactCarrier(
            wrongManifestReceipt.exactFramedBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "commitUploadResponse.receipt.requestBinding"
        )) {
            try HarcValidatedCommitUploadResponseV1(
                response,
                expectedRequest: commitRequest
            )
        }

        response.exactSignedRecordingReceipt = exactCarrier(Data([0x01]))
        #expect(throws: Error.self) {
            try HarcValidatedCommitUploadResponseV1(response)
        }

        let transportSet = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: fixture.hostKey,
            libraryID: fixture.libraryID
        )
        response.exactSignedRecordingReceipt = exactCarrier(
            transportSet.exactSignedBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "recordingReceipt"
        )) {
            try HarcValidatedCommitUploadResponseV1(response)
        }
    }

    @Test("terminal and status states require the matching evidence")
    func terminalAndStatusEvidence() throws {
        let fixture = try ResponseFixture()
        let statusRequest = try fixture.validatedStatusRequest()

        var status = fixture.statusResponse(state: .recordingIngestStateReceiving)
        _ = try HarcValidatedGetRecordingStatusResponseV1(
            status,
            expectedRequest: statusRequest
        )
        status.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            fixture.canonicalRecordingID
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "getRecordingStatusResponse.prepublicationEvidence"
        )) {
            try HarcValidatedGetRecordingStatusResponseV1(status)
        }

        status = fixture.statusResponse(state: .recordingIngestStateReceipted)
        status.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            fixture.canonicalRecordingID
        )
        status.canonicalRecordingRevision = 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "getRecordingStatusResponse.receiptEvidence"
        )) {
            try HarcValidatedGetRecordingStatusResponseV1(status)
        }

        let receipt = try fixture.receiptObject(
            uploadID: fixture.uploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: fixture.manifestObject.objectID
        )
        status.exactRecordingReceipt = exactCarrier(receipt.exactFramedBytes)
        let validated = try HarcValidatedGetRecordingStatusResponseV1(
            status,
            expectedRequest: statusRequest
        )
        #expect(validated.recordingReceipt?.exactBytes
            == receipt.exactFramedBytes)

        let otherReceipt = try fixture.receiptObject(
            uploadID: fixture.otherUploadID,
            originRecordingID: fixture.originRecordingID,
            manifestObjectSHA256: fixture.manifestObject.objectID
        )
        status.exactRecordingReceipt = exactCarrier(
            otherReceipt.exactFramedBytes
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "getRecordingStatusResponse.receipt"
        )) {
            try HarcValidatedGetRecordingStatusResponseV1(status)
        }

        var abandon = Harc_V1_AbandonUploadResponseV1()
        abandon.protocol = HarcProtocolVersion.v1.protobufV1()
        abandon.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        abandon.terminalReason = .uploadTerminalReasonUnspecified
        abandon.terminalAtUnixMs = ResponseFixture.issuedAt
        #expect(throws: HarcProtobufConversionError.unsupportedEnum(
            field: "abandonUploadResponse.terminalReason",
            rawValue: 0
        )) {
            try HarcValidatedAbandonUploadResponseV1(abandon)
        }
    }

    @Test("background capability binds HTTPS PUT, path, body, epoch, and expiry")
    func backgroundCapabilityBinding() throws {
        let fixture = try ResponseFixture()
        let request = try fixture.validatedBackgroundRequest()
        var response = try fixture.backgroundResponse()
        let validated = try HarcValidatedMintBackgroundCapabilityResponseV1(
            response,
            expectedRequest: request
        )
        #expect(validated.httpMethod == "PUT")
        #expect(validated.httpPath
            == "/v1/uploads/\(fixture.uploadID)/batches/\(fixture.batchID)")
        #expect(validated.exactTransportSet.exactBytes
            == response.exactSignedTransportSet.framedBytes)

        response.absoluteUploadURL = response.absoluteUploadURL
            .replacingOccurrences(of: "/batches/", with: "/wrong/")
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "mintBackgroundCapabilityResponse.httpPath"
        )) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(
                response,
                expectedRequest: request
            )
        }

        response = try fixture.backgroundResponse()
        response.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x77, count: 32)
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "mintBackgroundCapabilityResponse.requestBinding"
        )) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(
                response,
                expectedRequest: request
            )
        }

        response = try fixture.backgroundResponse()
        response.uploadGeneration += 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "mintBackgroundCapabilityResponse.requestBinding"
        )) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(
                response,
                expectedRequest: request
            )
        }

        response = try fixture.backgroundResponse()
        response.minimumTransportSetEpoch = 8
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "mintBackgroundCapabilityResponse.minimumTransportSetEpoch"
        )) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(response)
        }

        response = try fixture.backgroundResponse()
        response.expiresAtUnixMs -= 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "mintBackgroundCapabilityResponse.expiresAt"
        )) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(
                response,
                expectedRequest: request
            )
        }

        response = try fixture.backgroundResponse()
        var requirements = Harc_V1_ProtocolRequirementsV1()
        requirements.criticalFieldNumbers = [16]
        response.protocol = HarcProtocolVersion.v1.protobufV1(
            requirements: try HarcValidatedProtocolRequirements(
                requiredFeatures: [],
                criticalFieldNumbers: [16]
            )
        )
        _ = requirements
        #expect(throws: HarcProtobufConversionError.unknownCriticalField(16)) {
            try HarcValidatedMintBackgroundCapabilityResponseV1(response)
        }
    }
}

private struct ResponseFixture {
    static let issuedAt: UInt64 = 2_000_000_000_000
    static let expiresAt: UInt64 = issuedAt + 120_000

    let libraryID = LibraryID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    )
    let hostKey = ProtocolCodecFixtures.key(0x41)
    let deviceKey = ProtocolCodecFixtures.key(0x42)
    let uploadID = UploadID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    )
    let otherUploadID = UploadID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    )
    let batchID = AudioBatchID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
    )
    let canonicalRecordingID = CanonicalRecordingID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000005")!
    )
    let originRecordingID: OriginRecordingID
    let descriptor: LogicalChunkDescriptor
    let conflictingDescriptor: LogicalChunkDescriptor
    let twoDescriptors: [LogicalChunkDescriptor]
    let exactProfile: Data
    let profileSHA256: UploadProfileSHA256
    let manifestObject: HarcSignedObjectV1

    var hostAuthorityID: HostAuthorityID {
        hostKey.publicKey.hostAuthorityID
    }

    init() throws {
        originRecordingID = OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: UUID(
                uuidString: "20000000-0000-4000-8000-000000000006"
            )!
        )
        descriptor = try Self.makeDescriptor(
            origin: originRecordingID,
            index: 0,
            startFrame: 0,
            byte: 0x51
        )
        conflictingDescriptor = try Self.makeDescriptor(
            origin: originRecordingID,
            index: 0,
            startFrame: 0,
            byte: 0x54
        )
        let second = try Self.makeDescriptor(
            origin: originRecordingID,
            index: 1,
            startFrame: descriptor.canonicalEndFrameExclusive,
            byte: 0x52
        )
        twoDescriptors = [descriptor, second]

        var profile = Harc_V1_UploadProfileV1()
        profile.protocol = HarcProtocolVersion.v1.protobufV1()
        profile.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        profile.encoding = Harc_V1_LosslessEncodingConfigurationV1(.cafALAC)
        profile.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        profile.requiredCapabilityIds = []
        profile.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x53, count: 32)
        )
        profile.purpose = .uploadProfilePurposeProduction
        exactProfile = try HarcExactProtobufPayload(
            serializingOnce: profile
        ).exactBytes
        profileSHA256 = try UploadProfileSHA256(
            HarcSignedEnvelopeV1.payloadDigest(exactProfile)
        )

        let manifestPayload = Data([0x08, 0x01])
        let manifestHeader = try HarcSignedEnvelopeV1(
            messageType: .recordingManifest,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: deviceKey.publicKey.deviceID,
            grantID: nil,
            grantEpoch: 0,
            operationID: uploadID.rawValue,
            issuedAtUnixMilliseconds: Self.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingManifest,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(manifestPayload)
        )
        manifestObject = try HarcSignedObjectV1.sign(
            header: manifestHeader,
            exactPayloadBytes: manifestPayload,
            using: deviceKey
        )
    }

    func validatedBeginRequest() throws -> HarcValidatedBeginUploadRequestV1 {
        var value = Harc_V1_BeginUploadRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.libraryID = Harc_V1_LibraryIDV1(libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostAuthorityID)
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        value.producingDeviceID = Harc_V1_DeviceIDV1(
            originRecordingID.deviceID
        )
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        value.exactUploadProfilePayload = exactProfile
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return try HarcValidatedBeginUploadRequestV1(value)
    }

    func validatedDeclareRequest() throws
        -> HarcValidatedDeclareChunksRequestV1 {
        var value = Harc_V1_DeclareChunksRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.descriptors = [try Harc_V1_ChunkDescriptorV1(descriptor)]
        return try HarcValidatedDeclareChunksRequestV1(value)
    }

    func validatedUploadRequest() throws
        -> HarcValidatedUploadChunkRequestV1 {
        var value = Harc_V1_UploadChunkRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.chunkIndex = descriptor.chunkIndex
        value.chunkID = Harc_V1_ChunkIDV1(descriptor.chunkID)
        value.encodedByteLength = descriptor.encodedByteLength
        value.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: descriptor.encodedSHA256.rawBytes
        )
        value.encodedChunk = Data(repeating: 0x61, count: 4)
        return try HarcValidatedUploadChunkRequestV1(value)
    }

    func validatedReconcileRequest() throws
        -> HarcValidatedReconcileUploadRequestV1 {
        var value = Harc_V1_ReconcileUploadRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return try HarcValidatedReconcileUploadRequestV1(value)
    }

    func validatedCommitRequest() throws -> HarcValidatedCommitUploadRequestV1 {
        var value = Harc_V1_CommitUploadRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.exactSignedRecordingManifest = exactCarrier(
            manifestObject.exactFramedBytes
        )
        return try HarcValidatedCommitUploadRequestV1(value)
    }

    func validatedStatusRequest() throws
        -> HarcValidatedGetRecordingStatusRequestV1 {
        var value = Harc_V1_GetRecordingStatusRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        return try HarcValidatedGetRecordingStatusRequestV1(value)
    }

    func validatedBackgroundRequest() throws
        -> HarcValidatedMintBackgroundCapabilityRequestV1 {
        var value = Harc_V1_MintBackgroundCapabilityRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.batchID = Harc_V1_AudioBatchIDV1(batchID)
        var chunk = Harc_V1_BackgroundChunkBindingV1()
        chunk.chunkIndex = descriptor.chunkIndex
        chunk.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: descriptor.encodedSHA256.rawBytes
        )
        value.chunks = [chunk]
        value.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x71, count: 32)
        )
        value.exactBatchBodyLength = 4_096
        value.requestedExpiresAtUnixMs = Self.expiresAt
        return try HarcValidatedMintBackgroundCapabilityRequestV1(value)
    }

    func declareResponse() -> Harc_V1_DeclareChunksResponseV1 {
        var value = Harc_V1_DeclareChunksResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.disposition = .chunkDeclarationDispositionAppended
        value.firstAppendedIndex = descriptor.chunkIndex
        value.appendedCount = 1
        return value
    }

    func uploadAcknowledgementResponse() throws
        -> Harc_V1_UploadChunkResponseV1 {
        var ack = Harc_V1_ChunkAckV1()
        ack.protocol = HarcProtocolVersion.v1.protobufV1()
        ack.uploadID = Harc_V1_UploadIDV1(uploadID)
        ack.uploadGeneration = 2
        ack.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        ack.durableChunk = try Harc_V1_DurableChunkV1(
            DurableChunkStatus(
                chunkIndex: descriptor.chunkIndex,
                chunkID: descriptor.chunkID,
                encodedSHA256: descriptor.encodedSHA256
            )
        )
        ack.durableAtUnixMs = Self.issuedAt
        var value = Harc_V1_UploadChunkResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.result = .acknowledgement(ack)
        return value
    }

    func reconciliationResponse(
        declarations: [LogicalChunkDescriptor]? = nil
    ) throws -> Harc_V1_ReconcileUploadResponseV1 {
        var value = Harc_V1_ReconcileUploadResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.ownerDeviceID = Harc_V1_DeviceIDV1(originRecordingID.deviceID)
        value.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.uploadGeneration = 2
        value.firstBeganAtUnixMs = Self.issuedAt - 60_000
        value.generationBeganAtUnixMs = Self.issuedAt
        value.generationExpiresAtUnixMs = Self.expiresAt
        value.declarations = try (declarations ?? [descriptor]).map(
            Harc_V1_ChunkDescriptorV1.init
        )
        value.terminalReason = .uploadTerminalReasonUnspecified
        return value
    }

    func beginResponse() throws -> Harc_V1_BeginUploadResponseV1 {
        var value = Harc_V1_BeginUploadResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.disposition = .beginUploadDispositionCreated
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.generationExpiresAtUnixMs = Self.expiresAt
        value.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        value.reconciliation = try reconciliationResponse()
        return value
    }

    func statusResponse(
        state: Harc_V1_RecordingIngestStateV1
    ) -> Harc_V1_GetRecordingStatusResponseV1 {
        var value = Harc_V1_GetRecordingStatusResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        value.ingestState = state
        return value
    }

    func backgroundResponse() throws
        -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        let transportSet = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID,
            epoch: 7
        )
        var value = Harc_V1_MintBackgroundCapabilityResponseV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        let path = "/v1/uploads/\(uploadID)/batches/\(batchID)"
        value.absoluteUploadURL = "https://harc-test.local:7443\(path)"
        value.opaqueCapabilityCredential = Data(repeating: 0x72, count: 48)
        value.issuedAtUnixMs = Self.issuedAt
        value.expiresAtUnixMs = Self.expiresAt
        value.byteCeiling = 4_096
        value.minimumTransportSetEpoch = 7
        value.exactSignedTransportSet = exactCarrier(
            transportSet.exactSignedBytes
        )
        value.uploadID = Harc_V1_UploadIDV1(uploadID)
        value.uploadGeneration = 2
        value.batchID = Harc_V1_AudioBatchIDV1(batchID)
        value.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x71, count: 32)
        )
        value.httpMethod = "PUT"
        value.httpPath = path
        value.expiryWasClamped = false
        return value
    }

    func receiptObject(
        uploadID: UploadID,
        originRecordingID: OriginRecordingID,
        manifestObjectSHA256: ExactObjectSHA256,
        libraryID selectedLibraryID: LibraryID? = nil
    ) throws -> HarcSignedObjectV1 {
        let receiptLibraryID = selectedLibraryID ?? libraryID
        var receipt = Harc_V1_RecordingReceiptV1()
        receipt.protocol = HarcProtocolVersion.v1.protobufV1()
        receipt.libraryID = Harc_V1_LibraryIDV1(receiptLibraryID)
        receipt.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostAuthorityID)
        receipt.producingDeviceID = Harc_V1_DeviceIDV1(
            originRecordingID.deviceID
        )
        receipt.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        receipt.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            canonicalRecordingID
        )
        receipt.uploadID = Harc_V1_UploadIDV1(uploadID)
        receipt.signedManifestObjectSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: manifestObjectSHA256.rawBytes
        )
        receipt.canonicalPcmSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0x73, count: 32)
        )
        receipt.totalCanonicalFrames = 2
        receipt.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        receipt.canonicalRecordingRevision = 1
        receipt.changeCursor = 1
        receipt.issuedAtUnixMs = Self.issuedAt
        receipt.processingState = .recordingProcessingStatePending
        var receiptID = Harc_V1_ReceiptIDV1()
        receiptID.value = uuidBytes(
            UUID(uuidString: "20000000-0000-4000-8000-000000000007")!
        )
        receipt.receiptID = receiptID
        let payload = try HarcExactProtobufPayload(
            serializingOnce: receipt
        ).exactBytes
        let header = try HarcSignedEnvelopeV1(
            messageType: .recordingReceipt,
            libraryID: receiptLibraryID,
            hostAuthorityID: hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: uploadID.rawValue,
            issuedAtUnixMilliseconds: Self.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingReceipt,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        return try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: hostKey
        )
    }

    private static func makeDescriptor(
        origin: OriginRecordingID,
        index: UInt32,
        startFrame: UInt64,
        byte: UInt8
    ) throws -> LogicalChunkDescriptor {
        try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(
                UUID(
                    uuidString: String(
                        format:
                            "20000000-0000-4000-8000-%012u",
                        index + 100
                    )
                )!
            ),
            chunkIndex: index,
            canonicalStartFrame: startFrame,
            canonicalFrameCount: 2,
            encoding: .cafALAC,
            encodedByteLength: 4,
            encodedSHA256: try EncodedChunkSHA256(
                Data(repeating: byte, count: 32)
            ),
            canonicalDecodedByteLength: 4,
            canonicalDecodedSHA256: try CanonicalPCMHash(
                Data(repeating: byte &+ 1, count: 32)
            )
        )
    }
}

private func exactCarrier(_ bytes: Data) -> Harc_V1_ExactSignedObjectV1 {
    var value = Harc_V1_ExactSignedObjectV1()
    value.framedBytes = bytes
    return value
}

private func uuidBytes(_ value: UUID) -> Data {
    var raw = value.uuid
    return withUnsafeBytes(of: &raw) { Data($0) }
}
