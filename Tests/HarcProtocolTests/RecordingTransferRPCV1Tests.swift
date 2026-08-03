import Foundation
import HarcDomain
import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import SwiftProtobuf
import Testing

@Suite("Recording transfer RPC V1")
struct RecordingTransferRPCV1Tests {
    @Test("BeginUpload preserves exact profile bytes and rejects binding drift")
    func beginUploadExactProfileBinding() throws {
        let fixture = try Fixture()
        let validated = try HarcValidatedBeginUploadRequestV1(
            fixture.beginUploadRequest()
        )

        #expect(validated.protocolVersion == .v1)
        #expect(validated.libraryID == fixture.libraryID)
        #expect(validated.hostAuthorityID == fixture.hostAuthorityID)
        #expect(validated.uploadID == fixture.uploadID)
        #expect(validated.originRecordingID == fixture.originRecordingID)
        #expect(validated.producingDeviceID == fixture.deviceID)
        #expect(validated.profilePayload.exactPayload.exactBytes
            == fixture.exactProfile)
        #expect(validated.frozenProfile.profileSHA256 == fixture.profileSHA256)

        var nonCanonical = fixture.beginUploadRequest()
        let exactWithUnknownField = fixture.exactProfile
            + Data([0xa0, 0x06, 0x01])
        nonCanonical.exactUploadProfilePayload = exactWithUnknownField
        nonCanonical.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: HarcSignedEnvelopeV1.payloadDigest(
                exactWithUnknownField
            )
        )
        let preserved = try HarcValidatedBeginUploadRequestV1(nonCanonical)
        #expect(preserved.profilePayload.exactPayload.exactBytes
            == exactWithUnknownField)

        var wrongHash = fixture.beginUploadRequest()
        wrongHash.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0xee, count: 32)
        )
        #expect(throws: HarcProtobufConversionError.exactPayloadHashMismatch) {
            try HarcValidatedBeginUploadRequestV1(wrongHash)
        }

        var wrongProducer = fixture.beginUploadRequest()
        wrongProducer.producingDeviceID = Harc_V1_DeviceIDV1(
            try DeviceID(Data(repeating: 0xcc, count: 32))
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "beginUpload.producingDeviceID"
        )) {
            try HarcValidatedBeginUploadRequestV1(wrongProducer)
        }
    }

    @Test("BeginUpload profile is a compatible projection of session capabilities")
    func beginUploadSessionCompatibility() throws {
        let policy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue],
            supportedEncodings: [.cafALAC]
        )
        var negotiatedWire = Harc_V1_NegotiatedCapabilitiesV1()
        negotiatedWire.protocol = HarcProtocolVersion.v1.protobufV1()
        negotiatedWire.selectedFeatureIds = ["transfer.chunk.v1"]
        negotiatedWire.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        negotiatedWire.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            .cafALAC
        )
        negotiatedWire.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        let negotiated = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: negotiatedWire,
            policy: policy
        )

        let fixture = try Fixture(
            negotiatedCapabilitiesSHA256: negotiated.exactSHA256
        )
        let begin = try HarcValidatedBeginUploadRequestV1(
            fixture.beginUploadRequest()
        )
        try begin.validateInitialSessionCapabilities(negotiated)
        try begin.validateCompatibleSessionCapabilities(negotiated)

        negotiatedWire.selectedFeatureIds = []
        let missingFeature = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: negotiatedWire,
            policy: policy
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "transfer.negotiatedCapabilitiesSHA256"
        )) {
            try begin.validateInitialSessionCapabilities(missingFeature)
        }
        #expect(throws: HarcProtobufConversionError.unsupportedRequiredFeature(
            "transfer.chunk.v1"
        )) {
            try begin.validateCompatibleSessionCapabilities(missingFeature)
        }

        negotiatedWire.selectedFeatureIds = [
            "transfer.chunk.v1",
            "unrelated.library.feature.v1",
        ]
        let additivePolicy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [
                "transfer.chunk.v1",
                "unrelated.library.feature.v1",
            ],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
        let laterSession = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: negotiatedWire,
            policy: additivePolicy
        )
        try begin.validateCompatibleSessionCapabilities(laterSession)

        var reconcile = Harc_V1_ReconcileUploadRequestV1()
        reconcile.protocol = HarcProtocolVersion.v1.protobufV1()
        reconcile.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        reconcile.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.profileSHA256.rawBytes
        )
        let continuation = try HarcValidatedReconcileUploadRequestV1(
            reconcile
        )
        try continuation.validateCompatibleSessionCapabilities(
            laterSession,
            frozenProfile: begin.frozenProfile
        )

        negotiatedWire.encoding = Harc_V1_LosslessEncodingConfigurationV1(
            try .flac(compressionLevel: 5)
        )
        let codecPolicy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [
                "transfer.chunk.v1",
                "unrelated.library.feature.v1",
            ],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [
                .cafALAC,
                try .flac(compressionLevel: 5),
            ]
        )
        let wrongCodec = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: negotiatedWire,
            policy: codecPolicy
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "transfer.encoding"
        )) {
            try continuation.validateCompatibleSessionCapabilities(
                wrongCodec,
                frozenProfile: begin.frozenProfile
            )
        }
    }

    @Test("DeclareChunks and UploadChunk retain all immutable bindings")
    func declarationAndChunkValidation() throws {
        let fixture = try Fixture()
        let descriptor = try fixture.descriptor()

        var declaration = Harc_V1_DeclareChunksRequestV1()
        declaration.protocol = HarcProtocolVersion.v1.protobufV1()
        declaration.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        declaration.uploadGeneration = 3
        declaration.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.profileSHA256.rawBytes
        )
        declaration.descriptors = [
            try Harc_V1_ChunkDescriptorV1(descriptor),
        ]

        let declared = try HarcValidatedDeclareChunksRequestV1(declaration)
        #expect(declared.uploadID == fixture.uploadID)
        #expect(declared.generation.rawValue == 3)
        #expect(declared.uploadProfileSHA256 == fixture.profileSHA256)
        #expect(declared.descriptors == [descriptor])

        var descriptorWithUnknown = declaration.descriptors[0]
        let unknownDescriptorBytes = try descriptorWithUnknown.serializedData()
            + Data([0xa0, 0x06, 0x01])
        descriptorWithUnknown = try Harc_V1_ChunkDescriptorV1(
            serializedBytes: unknownDescriptorBytes
        )
        var unknownDeclaration = declaration
        unknownDeclaration.descriptors = [descriptorWithUnknown]
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "chunkDescriptor.unknownFields"
        )) {
            try HarcValidatedDeclareChunksRequestV1(unknownDeclaration)
        }

        var excessiveDeclaration = declaration
        excessiveDeclaration.descriptors = Array(
            repeating: declaration.descriptors[0],
            count: TransferLimits.declaredChunksPerCall + 1
        )
        #expect(throws: HarcProtobufConversionError.inputTooLarge(
            limit: TransferLimits.declaredChunksPerCall,
            actual: TransferLimits.declaredChunksPerCall + 1
        )) {
            try HarcValidatedDeclareChunksRequestV1(excessiveDeclaration)
        }

        var upload = Harc_V1_UploadChunkRequestV1()
        upload.protocol = HarcProtocolVersion.v1.protobufV1()
        upload.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        upload.uploadGeneration = 3
        upload.uploadProfileSha256 = declaration.uploadProfileSha256
        upload.chunkIndex = descriptor.chunkIndex
        upload.chunkID = Harc_V1_ChunkIDV1(descriptor.chunkID)
        upload.encodedByteLength = descriptor.encodedByteLength
        upload.encodedSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: descriptor.encodedSHA256.rawBytes
        )
        upload.encodedChunk = fixture.encodedChunk

        let validated = try HarcValidatedUploadChunkRequestV1(upload)
        #expect(validated.chunkID == descriptor.chunkID)
        #expect(validated.encodedSHA256 == descriptor.encodedSHA256)
        #expect(validated.encodedChunk == fixture.encodedChunk)

        var mismatchedLength = upload
        mismatchedLength.encodedByteLength += 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "uploadChunk.encodedChunk"
        )) {
            try HarcValidatedUploadChunkRequestV1(mismatchedLength)
        }

        var zeroGeneration = upload
        zeroGeneration.uploadGeneration = 0
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "uploadChunk.uploadGeneration"
        )) {
            try HarcValidatedUploadChunkRequestV1(zeroGeneration)
        }

        var overflowingGeneration = upload
        overflowingGeneration.uploadGeneration = UInt64(Int64.max) + 1
        #expect(throws: HarcProtobufConversionError.integerOutOfRange(
            field: "uploadChunk.uploadGeneration"
        )) {
            try HarcValidatedUploadChunkRequestV1(overflowingGeneration)
        }
    }

    @Test("commit, reconcile, abandon, and status keys fail closed")
    func lifecycleRequestValidation() throws {
        let fixture = try Fixture()

        var reconcile = Harc_V1_ReconcileUploadRequestV1()
        reconcile.protocol = HarcProtocolVersion.v1.protobufV1()
        reconcile.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        reconcile.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: fixture.profileSHA256.rawBytes
        )
        #expect(
            try HarcValidatedReconcileUploadRequestV1(reconcile)
                .uploadProfileSHA256 == fixture.profileSHA256
        )

        var commit = Harc_V1_CommitUploadRequestV1()
        commit.protocol = HarcProtocolVersion.v1.protobufV1()
        commit.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        commit.uploadGeneration = 2
        commit.uploadProfileSha256 = reconcile.uploadProfileSha256
        var exactManifest = Harc_V1_ExactSignedObjectV1()
        exactManifest.framedBytes = try fixture.structuralManifest()
        commit.exactSignedRecordingManifest = exactManifest
        #expect(
            try HarcValidatedCommitUploadRequestV1(commit)
                .exactSignedRecordingManifest == exactManifest.framedBytes
        )

        var missingManifest = commit
        missingManifest.clearExactSignedRecordingManifest()
        #expect(throws: HarcProtobufConversionError.missingField(
            "commitUpload.exactSignedRecordingManifest"
        )) {
            try HarcValidatedCommitUploadRequestV1(missingManifest)
        }

        var abandon = Harc_V1_AbandonUploadRequestV1()
        abandon.protocol = HarcProtocolVersion.v1.protobufV1()
        abandon.uploadID = Harc_V1_UploadIDV1(fixture.uploadID)
        abandon.uploadGeneration = 2
        abandon.uploadProfileSha256 = reconcile.uploadProfileSha256
        #expect(
            try HarcValidatedAbandonUploadRequestV1(abandon)
                .generation.rawValue == 2
        )

        var status = Harc_V1_GetRecordingStatusRequestV1()
        status.protocol = HarcProtocolVersion.v1.protobufV1()
        #expect(throws: HarcProtobufConversionError.missingField(
            "getRecordingStatus.recordingKey"
        )) {
            try HarcValidatedGetRecordingStatusRequestV1(status)
        }
        status.originRecordingID = Harc_V1_OriginRecordingIDV1(
            fixture.originRecordingID
        )
        #expect(
            try HarcValidatedGetRecordingStatusRequestV1(status)
                .recordingKey == .originRecordingID(fixture.originRecordingID)
        )
    }

    @Test("background capability bindings are bounded and canonically ordered")
    func backgroundCapabilityValidation() throws {
        let fixture = try Fixture()
        var request = try fixture.backgroundRequest(indexes: [0, 1])
        let validated = try HarcValidatedMintBackgroundCapabilityRequestV1(
            request
        )
        #expect(validated.chunks.map(\.chunkIndex) == [0, 1])
        #expect(validated.exactBatchBodyLength == 4_096)

        request = try fixture.backgroundRequest(indexes: [1, 0])
        #expect(throws: HarcProtobufConversionError.nonCanonicalOrder(
            field: "mintBackgroundCapability.chunks"
        )) {
            try HarcValidatedMintBackgroundCapabilityRequestV1(request)
        }

        request = try fixture.backgroundRequest(indexes: [0, 0])
        #expect(throws: HarcProtobufConversionError.duplicateValue(
            field: "mintBackgroundCapability.chunks"
        )) {
            try HarcValidatedMintBackgroundCapabilityRequestV1(request)
        }

        request = try fixture.backgroundRequest(indexes: [0])
        request.exactBatchBodyLength = TransferLimits.backgroundBatchBytes + 1
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "mintBackgroundCapability.exactBatchBodyLength"
        )) {
            try HarcValidatedMintBackgroundCapabilityRequestV1(request)
        }
    }

    @Test("reconciliation projection preserves durable state and exact receipt")
    func reconciliationProjection() throws {
        let fixture = try Fixture()
        let descriptor = try fixture.descriptor()
        let receipt = try OpaqueExactObjectSlot(
            kind: .recordingReceiptV1,
            exactBytes: Data("exact receipt".utf8),
            objectSHA256: ExactObjectSHA256(
                Data(repeating: 0x81, count: 32)
            )
        )
        let reconciliation = try UploadReconciliation(
            uploadID: fixture.uploadID,
            ownerDeviceID: fixture.deviceID,
            originRecordingID: fixture.originRecordingID,
            uploadProfileSHA256: fixture.profileSHA256,
            generation: try UploadGeneration(4),
            generationExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            declarations: [descriptor],
            boundManifestObjectSHA256: ExactObjectSHA256(
                Data(repeating: 0x82, count: 32)
            ),
            durableChunks: [
                DurableChunkStatus(
                    chunkIndex: descriptor.chunkIndex,
                    chunkID: descriptor.chunkID,
                    encodedSHA256: descriptor.encodedSHA256
                ),
            ],
            rejectedChunks: [],
            terminalReason: .committed,
            existingReceipt: receipt
        )

        let wire = try Harc_V1_ReconcileUploadResponseV1(reconciliation)
        #expect(wire.uploadGeneration == 4)
        #expect(wire.generationExpiresAtUnixMs == 2_000_000_000_000)
        #expect(wire.terminalReason == .uploadTerminalReasonCommitted)
        #expect(wire.durableChunks.count == 1)
        #expect(wire.exactExistingReceipt.framedBytes == receipt.exactBytes)
    }
}

private struct Fixture {
    let libraryID = LibraryID(
        UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    )
    let hostAuthorityID: HostAuthorityID
    let deviceID: DeviceID
    let uploadID = UploadID(
        UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    )
    let originRecordingID: OriginRecordingID
    let chunkID = ChunkID(
        UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    )
    let batchID = AudioBatchID(
        UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
    )
    let encodedChunk = Data([0x10, 0x20, 0x30, 0x40])
    let exactProfile: Data
    let profileSHA256: UploadProfileSHA256

    init(
        negotiatedCapabilitiesSHA256: Data = Data(repeating: 0xc3, count: 32)
    ) throws {
        hostAuthorityID = try HostAuthorityID(
            Data(repeating: 0xa1, count: 32)
        )
        deviceID = try DeviceID(Data(repeating: 0xb2, count: 32))
        originRecordingID = OriginRecordingID(
            deviceID: deviceID,
            recordingUUID: UUID(
                uuidString: "10000000-0000-4000-8000-000000000003"
            )!
        )

        var profile = Harc_V1_UploadProfileV1()
        profile.protocol = HarcProtocolVersion.v1.protobufV1()
        profile.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
        profile.encoding = Harc_V1_LosslessEncodingConfigurationV1(.cafALAC)
        profile.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        profile.requiredCapabilityIds = ["transfer.chunk.v1"]
        profile.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: negotiatedCapabilitiesSHA256
        )
        profile.purpose = .uploadProfilePurposeProduction
        exactProfile = try HarcExactProtobufPayload(
            serializingOnce: profile
        ).exactBytes
        profileSHA256 = try UploadProfileSHA256(
            HarcSignedEnvelopeV1.payloadDigest(exactProfile)
        )
    }

    func beginUploadRequest() -> Harc_V1_BeginUploadRequestV1 {
        var request = Harc_V1_BeginUploadRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.libraryID = Harc_V1_LibraryIDV1(libraryID)
        request.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostAuthorityID)
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.originRecordingID = Harc_V1_OriginRecordingIDV1(
            originRecordingID
        )
        request.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
        request.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        request.captureStartedAtUnixMs = 2_000_000_000_000
        request.captureStartedMonotonicNanoseconds = 123
        request.exactUploadProfilePayload = exactProfile
        request.uploadProfileSha256 = try! Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        return request
    }

    func descriptor() throws -> LogicalChunkDescriptor {
        try LogicalChunkDescriptor(
            originRecordingID: originRecordingID,
            chunkID: chunkID,
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 2,
            encoding: .cafALAC,
            encodedByteLength: UInt64(encodedChunk.count),
            encodedSHA256: EncodedChunkSHA256(
                Data(repeating: 0xd4, count: 32)
            ),
            canonicalDecodedByteLength: 4,
            canonicalDecodedSHA256: CanonicalPCMHash(
                Data(repeating: 0xe5, count: 32)
            )
        )
    }

    func backgroundRequest(
        indexes: [UInt32]
    ) throws -> Harc_V1_MintBackgroundCapabilityRequestV1 {
        var request = Harc_V1_MintBackgroundCapabilityRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.uploadID = Harc_V1_UploadIDV1(uploadID)
        request.uploadGeneration = 2
        request.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: profileSHA256.rawBytes
        )
        request.batchID = Harc_V1_AudioBatchIDV1(batchID)
        request.chunks = try indexes.map { index in
            var binding = Harc_V1_BackgroundChunkBindingV1()
            binding.chunkIndex = index
            binding.encodedSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: Data(repeating: UInt8(index + 1), count: 32)
            )
            return binding
        }
        request.exactBatchBodySha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: Data(repeating: 0xf6, count: 32)
        )
        request.exactBatchBodyLength = 4_096
        request.requestedExpiresAtUnixMs = 2_000_000_100_000
        return request
    }

    func structuralManifest() throws -> Data {
        let signer = ProtocolCodecFixtures.key(0x7a)
        let exactPayload = Data([0x08, 0x01])
        let header = try HarcSignedEnvelopeV1(
            messageType: .recordingManifest,
            libraryID: libraryID,
            hostAuthorityID: hostAuthorityID,
            signerDeviceID: signer.publicKey.deviceID,
            grantID: nil,
            grantEpoch: 0,
            operationID: uploadID.rawValue,
            issuedAtUnixMilliseconds: 2_000_000_000_000,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingManifest,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload)
        )
        return try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: exactPayload,
            using: signer
        ).exactFramedBytes
    }
}
