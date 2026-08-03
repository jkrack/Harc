import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Protocol security invariants")
struct ProtocolSecurityInvariantTests {
    @Test("portable trust history rejects a nested signed object of the wrong type")
    func trustHistoryRejectsWrongNestedType() throws {
        let fixture = trustFixture()
        let nestedHistory = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_010),
            issuedAt: fixture.exportedAt - 10,
            devices: []
        )
        let device = historicalDevice(
            fixture.deviceKey,
            grants: [nestedHistory]
        )
        let outer = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_011),
            issuedAt: fixture.exportedAt,
            devices: [device]
        )

        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "portableTrustHistory.signedGrantType"
        )) {
            try authenticateHistory(outer, authorityKey: fixture.authorityKey)
        }
    }

    @Test("invalid outer trust-history signature fails before deeply nested payload validation")
    func trustHistoryAuthenticatesOuterFrameBeforeRecursing() throws {
        let fixture = trustFixture()
        var nested = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_012),
            issuedAt: fixture.exportedAt - 100,
            devices: []
        )
        for index in 0 ..< 32 {
            nested = try portableHistoryObject(
                fixture: fixture,
                exportID: ProtocolCodecFixtures.uuid(9_013 + UInt32(index)),
                issuedAt: fixture.exportedAt - UInt64(99 - index),
                devices: [historicalDevice(fixture.deviceKey, grants: [nested])]
            )
        }

        var invalidOuterSignature = nested.exactFramedBytes
        invalidOuterSignature[invalidOuterSignature.count - 1] ^= 1
        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
                invalidOuterSignature,
                using: fixture.authorityKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("portable trust history rejects an excessive per-device object count")
    func trustHistoryRejectsExcessiveObjectCount() throws {
        let fixture = trustFixture()
        let grant = try deviceGrantObject(
            authorityKey: fixture.authorityKey,
            libraryID: fixture.libraryID,
            deviceKey: fixture.deviceKey,
            grantID: ProtocolCodecFixtures.uuid(9_046),
            grantEpoch: 1,
            issuedAt: fixture.exportedAt - 1
        )
        let outer = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_047),
            issuedAt: fixture.exportedAt,
            devices: [historicalDevice(
                fixture.deviceKey,
                grants: Array(repeating: grant, count: 1_025)
            )]
        )

        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "portableTrustHistory.signedGrants"
        )) {
            try authenticateHistory(outer, authorityKey: fixture.authorityKey)
        }
    }

    @Test("portable trust history rejects a nested grant from another authority")
    func trustHistoryRejectsWrongNestedAuthority() throws {
        let fixture = trustFixture()
        let otherAuthority = ProtocolCodecFixtures.key(93)
        let wrongAuthorityGrant = try deviceGrantObject(
            authorityKey: otherAuthority,
            libraryID: fixture.libraryID,
            deviceKey: fixture.deviceKey,
            grantID: ProtocolCodecFixtures.uuid(9_020),
            grantEpoch: 1,
            issuedAt: fixture.exportedAt - 10
        )
        let outer = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_021),
            issuedAt: fixture.exportedAt,
            devices: [historicalDevice(fixture.deviceKey, grants: [wrongAuthorityGrant])]
        )

        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(
            field: "hostAuthorityID"
        )) {
            try authenticateHistory(outer, authorityKey: fixture.authorityKey)
        }
    }

    @Test("portable trust history rejects descending nested grant order")
    func trustHistoryRejectsGrantOrder() throws {
        let fixture = trustFixture()
        let epochTwo = try deviceGrantObject(
            authorityKey: fixture.authorityKey,
            libraryID: fixture.libraryID,
            deviceKey: fixture.deviceKey,
            grantID: ProtocolCodecFixtures.uuid(9_030),
            grantEpoch: 2,
            issuedAt: fixture.exportedAt - 10
        )
        let epochOne = try deviceGrantObject(
            authorityKey: fixture.authorityKey,
            libraryID: fixture.libraryID,
            deviceKey: fixture.deviceKey,
            grantID: ProtocolCodecFixtures.uuid(9_031),
            grantEpoch: 1,
            issuedAt: fixture.exportedAt - 20
        )
        let outer = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_032),
            issuedAt: fixture.exportedAt,
            devices: [historicalDevice(fixture.deviceKey, grants: [epochTwo, epochOne])]
        )

        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "portableTrustHistory.signedGrants"
        )) {
            try authenticateHistory(outer, authorityKey: fixture.authorityKey)
        }
    }

    @Test("portable trust history rejects a nested grant issued after export")
    func trustHistoryRejectsPostExportGrant() throws {
        let fixture = trustFixture()
        let futureGrant = try deviceGrantObject(
            authorityKey: fixture.authorityKey,
            libraryID: fixture.libraryID,
            deviceKey: fixture.deviceKey,
            grantID: ProtocolCodecFixtures.uuid(9_040),
            grantEpoch: 1,
            issuedAt: fixture.exportedAt + 1
        )
        let outer = try portableHistoryObject(
            fixture: fixture,
            exportID: ProtocolCodecFixtures.uuid(9_041),
            issuedAt: fixture.exportedAt,
            devices: [historicalDevice(fixture.deviceKey, grants: [futureGrant])]
        )

        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "portableTrustHistory.grantIssuedAt"
        )) {
            try authenticateHistory(outer, authorityKey: fixture.authorityKey)
        }
    }

    @Test("recording manifests reject duplicate chunk IDs")
    func manifestRejectsDuplicateChunkID() throws {
        let fixture = manifestFixture()
        let duplicateID = ProtocolCodecFixtures.uuid(9_100)
        let object = try recordingManifestObject(
            fixture: fixture,
            chunkIDs: [duplicateID, duplicateID]
        )

        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "recordingManifest.chunkID"
        )) {
            try object.authenticateRegisteredPayload(
                using: fixture.deviceKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("recording manifests reject discontinuities in descending monotonic order")
    func manifestRejectsDiscontinuityOrder() throws {
        let fixture = manifestFixture()
        let discontinuities = [
            discontinuity(fixture: fixture, monotonicNanoseconds: 20),
            discontinuity(fixture: fixture, monotonicNanoseconds: 10),
        ]
        let object = try recordingManifestObject(
            fixture: fixture,
            chunkIDs: [ProtocolCodecFixtures.uuid(9_110)],
            discontinuities: discontinuities
        )

        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "recordingManifest.discontinuities"
        )) {
            try object.authenticateRegisteredPayload(
                using: fixture.deviceKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("processing provenance rejects controls and Unicode identifiers")
    func processingProvenanceRejectsNonCanonicalIdentifiers() throws {
        let fixture = processingFixture()
        let controlObject = try processingArtifactObject(fixture: fixture) {
            $0.engineRevision = "engine\nv1"
        }
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "processingArtifact.engineRevision"
        )) {
            try authenticateProcessing(controlObject, fixture: fixture)
        }

        let unicodeObject = try processingArtifactObject(fixture: fixture) {
            $0.wordTimingSchemaID = "harc.word-timing.é"
        }
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "processingArtifact.wordTimingSchemaID"
        )) {
            try authenticateProcessing(unicodeObject, fixture: fixture)
        }
    }

    @Test("audio batches accept the frame ceiling and reject one frame over it")
    func audioBatchEnforcesFrameMaximum() throws {
        let encoded = Data([0x01])
        let maximum = audioBatchHeader(
            encoded: encoded,
            canonicalFrames: TransferLimits.ordinaryChunkFrames,
            rawFixture: false
        )
        _ = try HarcAudioBatchV1.create(header: maximum, encodedChunks: [encoded])

        let overMaximum = audioBatchHeader(
            encoded: encoded,
            canonicalFrames: TransferLimits.ordinaryChunkFrames + 1,
            rawFixture: false
        )
        #expect(throws: HarcProtocolCodecError.invalidTimeRange(
            field: "audioBatch.entries[0].canonicalFrames"
        )) {
            try HarcAudioBatchV1.create(header: overMaximum, encodedChunks: [encoded])
        }
    }

    @Test("raw fixture descriptors bind encoded length and digest to canonical PCM")
    func audioBatchRejectsRawFixtureMismatch() throws {
        let encoded = Data([1, 2, 3, 4])
        let wrongLength = audioBatchHeader(
            encoded: encoded,
            canonicalFrames: 2,
            rawFixture: true,
            declaredEncodedLength: 3
        )
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(
            field: "audioBatch.entries[0].rawPCMFixture"
        )) {
            try HarcAudioBatchV1.create(header: wrongLength, encodedChunks: [encoded])
        }

        let wrongDigest = audioBatchHeader(
            encoded: encoded,
            canonicalFrames: 2,
            rawFixture: true,
            canonicalDigest: Data(repeating: 0xa5, count: 32)
        )
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(
            field: "audioBatch.entries[0].rawPCMFixture"
        )) {
            try HarcAudioBatchV1.create(header: wrongDigest, encodedChunks: [encoded])
        }
    }

    // MARK: - Portable trust history

    private struct TrustFixture {
        let authorityKey: SoftwareP256SigningKey
        let deviceKey: SoftwareP256SigningKey
        let libraryID: LibraryID
        let exportedAt: UInt64
    }

    private func trustFixture() -> TrustFixture {
        TrustFixture(
            authorityKey: ProtocolCodecFixtures.key(91),
            deviceKey: ProtocolCodecFixtures.key(92),
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(9_000)),
            exportedAt: ProtocolCodecFixtures.issuedAt
        )
    }

    private func deviceGrantObject(
        authorityKey: SoftwareP256SigningKey,
        libraryID: LibraryID,
        deviceKey: SoftwareP256SigningKey,
        grantID: UUID,
        grantEpoch: UInt64,
        issuedAt: UInt64
    ) throws -> HarcSignedObjectV1 {
        var value = Harc_V1_DeviceGrantV1()
        value.protocol = protocolVersion()
        value.libraryID = Harc_V1_LibraryIDV1(libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            authorityKey.publicKey.hostAuthorityID
        )
        value.grantID.value = uuidBytes(grantID)
        value.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        value.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        value.scopes = [.authorizationScopeRecordingUploadOwn]
        value.grantEpoch = grantEpoch
        value.issuedAtUnixMs = issuedAt
        value.minimumCompatibleProtocolMinor = 0
        value.maximumCompatibleProtocolMinor = 0
        let payload = try value.serializedData()
        return try signedObject(
            messageType: .deviceGrant,
            payloadType: .deviceGrant,
            payload: payload,
            libraryID: libraryID,
            authorityID: authorityKey.publicKey.hostAuthorityID,
            grantID: grantID,
            grantEpoch: grantEpoch,
            issuedAt: issuedAt,
            signer: authorityKey
        )
    }

    private func historicalDevice(
        _ deviceKey: SoftwareP256SigningKey,
        grants: [HarcSignedObjectV1]
    ) -> Harc_V1_HistoricalDeviceTrustV1 {
        var value = Harc_V1_HistoricalDeviceTrustV1()
        value.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        value.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        value.exactSignedDeviceGrants = grants.map { object in
            var carrier = Harc_V1_ExactSignedObjectV1()
            carrier.framedBytes = object.exactFramedBytes
            return carrier
        }
        return value
    }

    private func portableHistoryObject(
        fixture: TrustFixture,
        exportID: UUID,
        issuedAt: UInt64,
        devices: [Harc_V1_HistoricalDeviceTrustV1]
    ) throws -> HarcSignedObjectV1 {
        var value = Harc_V1_PortableTrustHistoryV1()
        value.protocol = protocolVersion()
        value.libraryID = Harc_V1_LibraryIDV1(fixture.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            fixture.authorityKey.publicKey.hostAuthorityID
        )
        value.oldHostAuthorityPublicKeyX963 = fixture.authorityKey.publicKey.rawBytes
        value.exportID.value = uuidBytes(exportID)
        value.issuedAtUnixMs = issuedAt
        value.devices = devices
        let payload = try value.serializedData()
        return try signedObject(
            messageType: .portableTrustHistory,
            payloadType: .portableTrustHistory,
            payload: payload,
            libraryID: fixture.libraryID,
            authorityID: fixture.authorityKey.publicKey.hostAuthorityID,
            operationID: exportID,
            issuedAt: issuedAt,
            signer: fixture.authorityKey
        )
    }

    private func authenticateHistory(
        _ object: HarcSignedObjectV1,
        authorityKey: SoftwareP256SigningKey
    ) throws {
        _ = try object.authenticateRegisteredPayload(
            using: authorityKey.publicKey,
            purpose: .historicalEvidence
        )
    }

    // MARK: - Recording manifest

    private struct ManifestFixture {
        let hostKey: SoftwareP256SigningKey
        let deviceKey: SoftwareP256SigningKey
        let libraryID: LibraryID
        let origin: Harc_V1_OriginRecordingIDV1
        let uploadID: UUID
    }

    private func manifestFixture() -> ManifestFixture {
        let hostKey = ProtocolCodecFixtures.key(101)
        let deviceKey = ProtocolCodecFixtures.key(102)
        var origin = Harc_V1_OriginRecordingIDV1()
        origin.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        origin.recordingUuid = uuidBytes(ProtocolCodecFixtures.uuid(9_101))
        return ManifestFixture(
            hostKey: hostKey,
            deviceKey: deviceKey,
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(9_102)),
            origin: origin,
            uploadID: ProtocolCodecFixtures.uuid(9_103)
        )
    }

    private func recordingManifestObject(
        fixture: ManifestFixture,
        chunkIDs: [UUID],
        discontinuities: [Harc_V1_CaptureDiscontinuityV1] = []
    ) throws -> HarcSignedObjectV1 {
        let totalFrames = UInt64(chunkIDs.count) * 2
        var value = Harc_V1_RecordingManifestV1()
        value.protocol = protocolVersion()
        value.manifestVersion = 1
        value.issuedAtUnixMs = ProtocolCodecFixtures.issuedAt
        value.libraryID = Harc_V1_LibraryIDV1(fixture.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            fixture.hostKey.publicKey.hostAuthorityID
        )
        value.originRecordingID = fixture.origin
        value.uploadID.value = uuidBytes(fixture.uploadID)
        value.producingDeviceID = Harc_V1_DeviceIDV1(fixture.deviceKey.publicKey.deviceID)
        value.uploadProfileSha256.value = digest(0x31)
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = alacEncoding()
        value.captureStartedAtUnixMs = ProtocolCodecFixtures.issuedAt - 1_000
        value.captureEndedAtUnixMs = ProtocolCodecFixtures.issuedAt - 1
        value.captureStartedMonotonicNanoseconds = 1
        value.captureEndedMonotonicNanoseconds = 100
        value.finalizationReason = .captureFinalizationReasonUserStopped
        value.canonicalFormat = canonicalFormat()
        value.totalCanonicalFrames = totalFrames
        value.totalCanonicalBytes = totalFrames * 2
        value.canonicalPcmSha256.value = digest(0x32)
        value.chunks = chunkIDs.enumerated().map { index, chunkID in
            var chunk = Harc_V1_ChunkDescriptorV1()
            chunk.originRecordingID = fixture.origin
            chunk.chunkID.value = uuidBytes(chunkID)
            chunk.chunkIndex = UInt32(index)
            chunk.canonicalStartFrame = UInt64(index) * 2
            chunk.canonicalFrameCount = 2
            chunk.canonicalFormat = canonicalFormat()
            chunk.encoding = alacEncoding()
            chunk.encodedByteLength = 3
            chunk.encodedSha256.value = digest(UInt8(0x40 + index))
            chunk.canonicalDecodedByteLength = 4
            chunk.canonicalDecodedSha256.value = digest(UInt8(0x50 + index))
            return chunk
        }
        value.discontinuities = discontinuities
        let payload = try value.serializedData()
        return try signedObject(
            messageType: .recordingManifest,
            payloadType: .recordingManifest,
            payload: payload,
            libraryID: fixture.libraryID,
            authorityID: fixture.hostKey.publicKey.hostAuthorityID,
            signerDeviceID: fixture.deviceKey.publicKey.deviceID,
            operationID: fixture.uploadID,
            issuedAt: value.issuedAtUnixMs,
            signer: fixture.deviceKey
        )
    }

    private func discontinuity(
        fixture: ManifestFixture,
        monotonicNanoseconds: UInt64
    ) -> Harc_V1_CaptureDiscontinuityV1 {
        var value = Harc_V1_CaptureDiscontinuityV1()
        value.originRecordingID = fixture.origin
        value.monotonicTimeNanoseconds = monotonicNanoseconds
        value.wallTimeUnixMs = ProtocolCodecFixtures.issuedAt - 500
        value.reason = .captureDiscontinuityReasonInterruptionBegan
        value.affectedFrames.startFrame = 0
        value.affectedFrames.endFrameExclusive = 1
        value.canonicalizationPolicy = .captureCanonicalizationPolicyPreserveCapturedPcm
        return value
    }

    // MARK: - Processing provenance

    private struct ProcessingFixture {
        let hostKey: SoftwareP256SigningKey
        let deviceKey: SoftwareP256SigningKey
        let libraryID: LibraryID
        let grantID: UUID
        let operationID: UUID
        let origin: Harc_V1_OriginRecordingIDV1
    }

    private func processingFixture() -> ProcessingFixture {
        let hostKey = ProtocolCodecFixtures.key(111)
        let deviceKey = ProtocolCodecFixtures.key(112)
        var origin = Harc_V1_OriginRecordingIDV1()
        origin.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        origin.recordingUuid = uuidBytes(ProtocolCodecFixtures.uuid(9_201))
        return ProcessingFixture(
            hostKey: hostKey,
            deviceKey: deviceKey,
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(9_202)),
            grantID: ProtocolCodecFixtures.uuid(9_203),
            operationID: ProtocolCodecFixtures.uuid(9_204),
            origin: origin
        )
    }

    private func processingArtifactObject(
        fixture: ProcessingFixture,
        mutate: (inout Harc_V1_ProcessingArtifactV1) -> Void
    ) throws -> HarcSignedObjectV1 {
        var value = Harc_V1_ProcessingArtifactV1()
        value.protocol = protocolVersion()
        value.libraryID = Harc_V1_LibraryIDV1(fixture.libraryID)
        value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            fixture.hostKey.publicKey.hostAuthorityID
        )
        value.artifactID.value = uuidBytes(ProtocolCodecFixtures.uuid(9_205))
        value.originRecordingID = fixture.origin
        value.canonicalAudioSha256.value = digest(0x61)
        value.producingDeviceID = Harc_V1_DeviceIDV1(fixture.deviceKey.publicKey.deviceID)
        value.grantID.value = uuidBytes(fixture.grantID)
        value.grantEpoch = 1
        value.operationID.value = uuidBytes(fixture.operationID)
        value.issuedAtUnixMs = ProtocolCodecFixtures.issuedAt
        value.submissionExpiresAtUnixMs = ProtocolCodecFixtures.issuedAt + 60_000
        value.engineRevision = "engine.v1"
        value.buildRevision = "build.v1"
        value.diarizationRevision = "diarization.v1"
        value.vadRevision = "vad.v1"
        value.vocabularyRevision = "vocabulary.v1"
        value.promptRevision = "prompt.v1"
        value.wordTimingSchemaID = "harc.word-timing.v1"
        value.coverage.coveredRanges = [frameRange(start: 0, end: 2)]
        value.exactBundleByteLength = 1
        value.exactBundleSha256.value = digest(0x62)
        mutate(&value)
        let payload = try value.serializedData()
        return try signedObject(
            messageType: .processingArtifact,
            payloadType: .processingArtifact,
            payload: payload,
            libraryID: fixture.libraryID,
            authorityID: fixture.hostKey.publicKey.hostAuthorityID,
            signerDeviceID: fixture.deviceKey.publicKey.deviceID,
            grantID: fixture.grantID,
            grantEpoch: 1,
            operationID: fixture.operationID,
            issuedAt: value.issuedAtUnixMs,
            expiresAt: value.submissionExpiresAtUnixMs,
            signer: fixture.deviceKey
        )
    }

    private func authenticateProcessing(
        _ object: HarcSignedObjectV1,
        fixture: ProcessingFixture
    ) throws {
        _ = try object.authenticateRegisteredPayload(
            using: fixture.deviceKey.publicKey,
            purpose: .initialCommandAcceptance(
                acceptedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1,
                currentGrant: ProtocolCodecFixtures.currentGrantBinding(
                    libraryID: fixture.libraryID,
                    hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
                    deviceKey: fixture.deviceKey,
                    grantID: fixture.grantID,
                    grantEpoch: 1,
                    scopes: [.processingSubmitOwn]
                )
            )
        )
    }

    // MARK: - Audio batches and shared wire helpers

    private func audioBatchHeader(
        encoded: Data,
        canonicalFrames: UInt64,
        rawFixture: Bool,
        declaredEncodedLength: UInt32? = nil,
        canonicalDigest: Data? = nil
    ) -> Harc_V1_AudioBatchHeaderV1 {
        let encodedDigest = Data(SHA256.hash(data: encoded))
        var header = Harc_V1_AudioBatchHeaderV1()
        header.protocol = protocolVersion()
        header.batchID.value = uuidBytes(ProtocolCodecFixtures.uuid(9_300))
        header.uploadID.value = uuidBytes(ProtocolCodecFixtures.uuid(9_301))
        header.uploadProfileSha256.value = digest(0x71)
        header.originRecordingID.deviceID.sha256 = digest(0x72)
        header.originRecordingID.recordingUuid = uuidBytes(ProtocolCodecFixtures.uuid(9_302))
        header.deviceID.sha256 = digest(0x72)

        var entry = Harc_V1_AudioBatchEntryV1()
        entry.chunkID.value = uuidBytes(ProtocolCodecFixtures.uuid(9_303))
        entry.chunkIndex = 0
        entry.encodedLength = declaredEncodedLength ?? UInt32(encoded.count)
        entry.encodedSha256.value = encodedDigest
        entry.canonicalStartFrame = 0
        entry.canonicalFrameCount = canonicalFrames
        entry.canonicalDecodedSha256.value = canonicalDigest ?? encodedDigest
        if rawFixture {
            entry.encoding.codec = .losslessAudioCodecRawCanonicalPcmFixture
            entry.encoding.container = .losslessAudioContainerRawCanonicalPcmFixture
        } else {
            entry.encoding.codec = .losslessAudioCodecAppleLossless
            entry.encoding.container = .losslessAudioContainerCoreAudioFormat
        }
        header.entries = [entry]
        return header
    }

    private func signedObject(
        messageType: HarcSignedMessageTypeV1,
        payloadType: HarcSignedPayloadTypeV1,
        payload: Data,
        libraryID: LibraryID,
        authorityID: HostAuthorityID,
        signerDeviceID: DeviceID? = nil,
        grantID: UUID? = nil,
        grantEpoch: UInt64 = 0,
        operationID: UUID? = nil,
        issuedAt: UInt64,
        expiresAt: UInt64? = nil,
        signer: SoftwareP256SigningKey
    ) throws -> HarcSignedObjectV1 {
        let header = try HarcSignedEnvelopeV1(
            messageType: messageType,
            libraryID: libraryID,
            hostAuthorityID: authorityID,
            signerDeviceID: signerDeviceID,
            grantID: grantID,
            grantEpoch: grantEpoch,
            operationID: operationID,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiresAt,
            payloadType: payloadType,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        return try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: signer
        )
    }

    private func protocolVersion() -> Harc_V1_ProtocolVersionV1 {
        HarcProtocolVersion.v1.protobufV1()
    }

    private func canonicalFormat() -> Harc_V1_CanonicalPCMFormatV1 {
        var value = Harc_V1_CanonicalPCMFormatV1()
        value.sampleRateHz = 16_000
        value.channelCount = 1
        value.encoding = .canonicalPcmEncodingSignedInt16LittleEndian
        return value
    }

    private func alacEncoding() -> Harc_V1_LosslessEncodingConfigurationV1 {
        var value = Harc_V1_LosslessEncodingConfigurationV1()
        value.codec = .losslessAudioCodecAppleLossless
        value.container = .losslessAudioContainerCoreAudioFormat
        return value
    }

    private func frameRange(start: UInt64, end: UInt64) -> Harc_V1_CanonicalFrameRangeV1 {
        var value = Harc_V1_CanonicalFrameRangeV1()
        value.startFrame = start
        value.endFrameExclusive = end
        return value
    }

    private func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
