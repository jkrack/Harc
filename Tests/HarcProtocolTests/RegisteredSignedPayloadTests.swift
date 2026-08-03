import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import Testing

@Suite("Typed registered signed-payload authentication")
struct RegisteredSignedPayloadTests {
    @Test("host transport authentication derives mirrors from exact binary payload")
    func hostTransportAuthentication() throws {
        let hostKey = ProtocolCodecFixtures.key(60)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(600))
        let transport = try ProtocolCodecFixtures.verifiedTransportSet(
            hostKey: hostKey,
            libraryID: libraryID
        )

        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            transport.exactSignedBytes,
            using: hostKey.publicKey,
            purpose: .historicalEvidence
        )
        guard case .hostTransportSet(let decoded) = authenticated.payload else {
            Issue.record("Expected typed host transport payload")
            return
        }
        #expect(decoded == transport.transportSet)
        #expect(authenticated.signedObject.exactFramedBytes == transport.exactSignedBytes)
    }

    @Test("device grant authentication parses exact protobuf before accepting mirrors")
    func deviceGrantAuthentication() throws {
        let fixture = try grantFixture()
        let authenticated = try fixture.object.authenticateRegisteredPayload(
            using: fixture.hostKey.publicKey,
            purpose: .historicalEvidence
        )
        guard case .deviceGrant(let exact, let claims) = authenticated.payload else {
            Issue.record("Expected typed device grant payload")
            return
        }
        #expect(exact.exactBytes == fixture.payload)
        #expect(claims.libraryID == fixture.libraryID)
        #expect(claims.deviceID == fixture.deviceKey.publicKey.deviceID)
        #expect(claims.grantID.rawValue == fixture.grantID)
        #expect(claims.grantEpoch.rawValue == 1)
    }

    @Test("signed arbitrary bytes cannot substitute caller-invented bindings")
    func arbitraryPayloadCannotAuthenticate() throws {
        let hostKey = ProtocolCodecFixtures.key(63)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(630))
        let grantID = ProtocolCodecFixtures.uuid(631)
        let arbitrary = Data([0x08, 0x01])
        let header = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: grantID,
            grantEpoch: 1,
            operationID: nil,
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(arbitrary)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: arbitrary,
            using: hostKey
        )

        #expect(throws: Error.self) {
            try object.authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("payload-derived grant mirrors reject a differently bound envelope")
    func mismatchedGrantMirror() throws {
        let fixture = try grantFixture()
        let wrongGrantID = ProtocolCodecFixtures.uuid(699)
        let wrongHeader = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            libraryID: fixture.libraryID,
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: wrongGrantID,
            grantEpoch: 1,
            operationID: nil,
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(fixture.payload)
        )
        let wrongObject = try HarcSignedObjectV1.sign(
            header: wrongHeader,
            exactPayloadBytes: fixture.payload,
            using: fixture.hostKey
        )

        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(field: "grantID")) {
            try wrongObject.authenticateRegisteredPayload(
                using: fixture.hostKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("unknown critical fields fail before a signed grant becomes trusted")
    func unknownCriticalField() throws {
        var fixture = try grantFixture().wire
        fixture.protocol.requirements.criticalFieldNumbers = [13]
        let payload = try fixture.serializedData()
        let hostKey = ProtocolCodecFixtures.key(64)
        let header = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            libraryID: try fixture.libraryID.domainValue(),
            hostAuthorityID: try fixture.hostAuthorityID.domainValue(),
            signerDeviceID: nil,
            grantID: try fixture.grantID.domainValue().rawValue,
            grantEpoch: fixture.grantEpoch,
            operationID: nil,
            issuedAtUnixMilliseconds: fixture.issuedAtUnixMs,
            expiresAtUnixMilliseconds: nil,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        // Rebind the fixture authority to this signing key so the signature-key
        // check cannot hide the compatibility failure under test.
        fixture.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostKey.publicKey.hostAuthorityID)
        let reboundPayload = try fixture.serializedData()
        let reboundHeader = try HarcSignedEnvelopeV1(
            messageType: header.messageType,
            libraryID: header.libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: header.grantID,
            grantEpoch: header.grantEpoch,
            operationID: nil,
            issuedAtUnixMilliseconds: header.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: nil,
            payloadType: header.payloadType,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(reboundPayload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: reboundHeader,
            exactPayloadBytes: reboundPayload,
            using: hostKey
        )
        #expect(throws: HarcProtobufConversionError.unknownCriticalField(13)) {
            try object.authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            )
        }
    }

    @Test("initial command authentication requires the current grant")
    func commandRequiresCurrentGrant() throws {
        let hostKey = ProtocolCodecFixtures.key(65)
        let deviceKey = ProtocolCodecFixtures.key(66)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(650))
        let grantID = ProtocolCodecFixtures.uuid(651)
        let operationID = ProtocolCodecFixtures.uuid(652)
        let issuedAt = ProtocolCodecFixtures.issuedAt

        var mutation = Harc_V1_MetadataMutationV1()
        mutation.protocol = wireProtocol()
        mutation.libraryID = Harc_V1_LibraryIDV1(libraryID)
        mutation.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostKey.publicKey.hostAuthorityID)
        mutation.requestingDeviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        mutation.grantID.value = uuidBytes(grantID)
        mutation.grantEpoch = 2
        mutation.operationID.value = uuidBytes(operationID)
        mutation.issuedAtUnixMs = issuedAt
        mutation.expiresAtUnixMs = issuedAt + 60_000
        mutation.canonicalRecordingID.value = uuidBytes(ProtocolCodecFixtures.uuid(653))
        mutation.expectedRevision = 1
        mutation.setPinned.pinned = true
        let payload = try mutation.serializedData()
        let header = try HarcSignedEnvelopeV1(
            messageType: .metadataMutation,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: deviceKey.publicKey.deviceID,
            grantID: grantID,
            grantEpoch: 2,
            operationID: operationID,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: issuedAt + 60_000,
            payloadType: .metadataMutation,
            expectedRevision: 1,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: deviceKey
        )

        let stale = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 1,
            scopes: [.libraryMetadataWrite]
        )
        #expect(throws: HarcProtocolCodecError.staleGrant) {
            try object.authenticateRegisteredPayload(
                using: deviceKey.publicKey,
                purpose: .initialCommandAcceptance(
                    acceptedAtUnixMilliseconds: issuedAt + 1,
                    currentGrant: stale
                )
            )
        }
        let current = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 2,
            scopes: [.libraryMetadataWrite]
        )
        _ = try object.authenticateRegisteredPayload(
            using: deviceKey.publicKey,
            purpose: .initialCommandAcceptance(
                acceptedAtUnixMilliseconds: issuedAt + 1,
                currentGrant: current
            )
        )
    }

    @Test("the remaining six registered payload rows decode and authenticate by exact type")
    func remainingRegisteredRows() throws {
        let hostKey = ProtocolCodecFixtures.key(67)
        let deviceKey = ProtocolCodecFixtures.key(68)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(670))
        let authorityID = hostKey.publicKey.hostAuthorityID
        let deviceID = deviceKey.publicKey.deviceID
        let grantID = ProtocolCodecFixtures.uuid(671)
        let issuedAt = ProtocolCodecFixtures.issuedAt

        var revocation = Harc_V1_DeviceRevocationV1()
        revocation.protocol = wireProtocol()
        revocation.libraryID = Harc_V1_LibraryIDV1(libraryID)
        revocation.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        revocation.deviceID = Harc_V1_DeviceIDV1(deviceID)
        revocation.grantID.value = uuidBytes(grantID)
        revocation.priorGrantEpoch = 1
        revocation.newGrantEpoch = 2
        let revocationID = ProtocolCodecFixtures.uuid(672)
        revocation.revocationID.value = uuidBytes(revocationID)
        revocation.reasonCode = "user.revoked"
        revocation.issuedAtUnixMs = issuedAt
        let revocationObject = try signedObject(
            messageType: .deviceRevocation,
            payloadType: .deviceRevocation,
            payload: revocation.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            grantID: grantID,
            grantEpoch: 2,
            operationID: revocationID,
            issuedAt: issuedAt,
            signer: hostKey
        )
        guard case .deviceRevocation = try revocationObject
            .authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            ).payload else {
            Issue.record("Expected revocation payload")
            return
        }

        let originRecordingUUID = ProtocolCodecFixtures.uuid(673)
        let uploadID = ProtocolCodecFixtures.uuid(674)
        var manifest = Harc_V1_RecordingManifestV1()
        manifest.protocol = wireProtocol()
        manifest.manifestVersion = 1
        manifest.issuedAtUnixMs = issuedAt
        manifest.libraryID = Harc_V1_LibraryIDV1(libraryID)
        manifest.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        manifest.originRecordingID = origin(deviceID: deviceID, recordingUUID: originRecordingUUID)
        manifest.uploadID.value = uuidBytes(uploadID)
        manifest.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
        manifest.uploadProfileSha256.value = digest(0x70)
        manifest.descriptorSchemaID = "harc.chunk-descriptor.v1"
        manifest.encoding = alacEncoding()
        manifest.captureStartedAtUnixMs = issuedAt - 10_000
        manifest.captureEndedAtUnixMs = issuedAt - 1
        manifest.captureStartedMonotonicNanoseconds = 10
        manifest.captureEndedMonotonicNanoseconds = 20
        manifest.finalizationReason = .captureFinalizationReasonUserStopped
        manifest.canonicalFormat = canonicalFormat()
        manifest.totalCanonicalFrames = 2
        manifest.totalCanonicalBytes = 4
        manifest.canonicalPcmSha256.value = digest(0x71)
        var chunk = Harc_V1_ChunkDescriptorV1()
        chunk.originRecordingID = manifest.originRecordingID
        chunk.chunkID.value = uuidBytes(ProtocolCodecFixtures.uuid(675))
        chunk.chunkIndex = 0
        chunk.canonicalStartFrame = 0
        chunk.canonicalFrameCount = 2
        chunk.canonicalFormat = canonicalFormat()
        chunk.encoding = alacEncoding()
        chunk.encodedByteLength = 4
        chunk.encodedSha256.value = digest(0x72)
        chunk.canonicalDecodedByteLength = 4
        chunk.canonicalDecodedSha256.value = digest(0x71)
        manifest.chunks = [chunk]
        let manifestObject = try signedObject(
            messageType: .recordingManifest,
            payloadType: .recordingManifest,
            payload: manifest.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            signerDeviceID: deviceID,
            operationID: uploadID,
            issuedAt: issuedAt,
            signer: deviceKey
        )
        guard case .recordingManifest = try manifestObject
            .authenticateRegisteredPayload(
                using: deviceKey.publicKey,
                purpose: .historicalEvidence
            ).payload else {
            Issue.record("Expected recording manifest payload")
            return
        }

        let batchID = ProtocolCodecFixtures.uuid(676)
        var batchAck = Harc_V1_BatchAckV1()
        batchAck.protocol = wireProtocol()
        batchAck.libraryID = Harc_V1_LibraryIDV1(libraryID)
        batchAck.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        batchAck.deviceID = Harc_V1_DeviceIDV1(deviceID)
        batchAck.uploadID.value = uuidBytes(uploadID)
        batchAck.batchID.value = uuidBytes(batchID)
        batchAck.exactBatchBodySha256.value = digest(0x73)
        var acceptedChunk = Harc_V1_AcceptedBatchChunkV1()
        acceptedChunk.chunkIndex = 0
        acceptedChunk.encodedSha256.value = digest(0x72)
        batchAck.acceptedChunks = [acceptedChunk]
        batchAck.durableAtUnixMs = issuedAt
        batchAck.ackID.value = uuidBytes(ProtocolCodecFixtures.uuid(677))
        batchAck.issuedAtUnixMs = issuedAt
        let batchObject = try signedObject(
            messageType: .batchAcknowledgement,
            payloadType: .batchAcknowledgement,
            payload: batchAck.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            operationID: batchID,
            issuedAt: issuedAt,
            signer: hostKey
        )
        guard case .batchAcknowledgement = try batchObject
            .authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            ).payload else {
            Issue.record("Expected batch acknowledgement payload")
            return
        }

        var receipt = Harc_V1_RecordingReceiptV1()
        receipt.protocol = wireProtocol()
        receipt.libraryID = Harc_V1_LibraryIDV1(libraryID)
        receipt.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        receipt.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
        receipt.originRecordingID = manifest.originRecordingID
        receipt.canonicalRecordingID.value = uuidBytes(ProtocolCodecFixtures.uuid(678))
        receipt.uploadID.value = uuidBytes(uploadID)
        receipt.signedManifestObjectSha256.value = manifestObject.objectID.rawBytes
        receipt.canonicalPcmSha256.value = digest(0x71)
        receipt.totalCanonicalFrames = 2
        receipt.canonicalFormat = canonicalFormat()
        receipt.canonicalRecordingRevision = 1
        receipt.changeCursor = 1
        receipt.issuedAtUnixMs = issuedAt
        receipt.processingState = .recordingProcessingStatePending
        receipt.receiptID.value = uuidBytes(ProtocolCodecFixtures.uuid(679))
        let receiptObject = try signedObject(
            messageType: .recordingReceipt,
            payloadType: .recordingReceipt,
            payload: receipt.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            operationID: uploadID,
            issuedAt: issuedAt,
            signer: hostKey
        )
        guard case .recordingReceipt = try receiptObject
            .authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            ).payload else {
            Issue.record("Expected recording receipt payload")
            return
        }

        var artifact = Harc_V1_ProcessingArtifactV1()
        artifact.protocol = wireProtocol()
        artifact.libraryID = Harc_V1_LibraryIDV1(libraryID)
        artifact.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        artifact.artifactID.value = uuidBytes(ProtocolCodecFixtures.uuid(680))
        artifact.originRecordingID = manifest.originRecordingID
        artifact.canonicalAudioSha256.value = digest(0x71)
        artifact.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
        artifact.grantID.value = uuidBytes(grantID)
        artifact.grantEpoch = 2
        let processingOperationID = ProtocolCodecFixtures.uuid(681)
        artifact.operationID.value = uuidBytes(processingOperationID)
        artifact.issuedAtUnixMs = issuedAt
        artifact.submissionExpiresAtUnixMs = issuedAt + 60_000
        artifact.engineRevision = "engine-v1"
        artifact.buildRevision = "build-v1"
        artifact.diarizationRevision = "diarization-v1"
        artifact.vadRevision = "vad-v1"
        artifact.vocabularyRevision = "vocabulary-v1"
        artifact.promptRevision = "prompt-v1"
        artifact.wordTimingSchemaID = "harc.word-timing.v1"
        var covered = Harc_V1_CanonicalFrameRangeV1()
        covered.startFrame = 0
        covered.endFrameExclusive = 2
        artifact.coverage.coveredRanges = [covered]
        artifact.exactBundleByteLength = 1
        artifact.exactBundleSha256.value = digest(0x74)
        let artifactObject = try signedObject(
            messageType: .processingArtifact,
            payloadType: .processingArtifact,
            payload: artifact.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            signerDeviceID: deviceID,
            grantID: grantID,
            grantEpoch: 2,
            operationID: processingOperationID,
            issuedAt: issuedAt,
            expiresAt: issuedAt + 60_000,
            signer: deviceKey
        )
        guard case .processingArtifact = try artifactObject
            .authenticateRegisteredPayload(
                using: deviceKey.publicKey,
                purpose: .initialCommandAcceptance(
                    acceptedAtUnixMilliseconds: issuedAt + 1,
                    currentGrant: ProtocolCodecFixtures.currentGrantBinding(
                        libraryID: libraryID,
                        hostAuthorityID: authorityID,
                        deviceKey: deviceKey,
                        grantID: grantID,
                        grantEpoch: 2,
                        scopes: [.processingSubmitOwn]
                    )
                )
            ).payload else {
            Issue.record("Expected processing artifact payload")
            return
        }

        let exportID = ProtocolCodecFixtures.uuid(682)
        var historicalGrant = Harc_V1_DeviceGrantV1()
        historicalGrant.protocol = wireProtocol()
        historicalGrant.libraryID = Harc_V1_LibraryIDV1(libraryID)
        historicalGrant.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        historicalGrant.grantID.value = uuidBytes(grantID)
        historicalGrant.deviceID = Harc_V1_DeviceIDV1(deviceID)
        historicalGrant.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        historicalGrant.scopes = [.authorizationScopeRecordingUploadOwn]
        historicalGrant.grantEpoch = 1
        historicalGrant.issuedAtUnixMs = issuedAt - 1
        historicalGrant.minimumCompatibleProtocolMinor = 0
        historicalGrant.maximumCompatibleProtocolMinor = 0
        let historicalGrantObject = try signedObject(
            messageType: .deviceGrant,
            payloadType: .deviceGrant,
            payload: historicalGrant.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            grantID: grantID,
            grantEpoch: 1,
            issuedAt: issuedAt - 1,
            signer: hostKey
        )

        var history = Harc_V1_PortableTrustHistoryV1()
        history.protocol = wireProtocol()
        history.libraryID = Harc_V1_LibraryIDV1(libraryID)
        history.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
        history.oldHostAuthorityPublicKeyX963 = hostKey.publicKey.rawBytes
        history.exportID.value = uuidBytes(exportID)
        history.issuedAtUnixMs = issuedAt
        var historicalDevice = Harc_V1_HistoricalDeviceTrustV1()
        historicalDevice.deviceID = Harc_V1_DeviceIDV1(deviceID)
        historicalDevice.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        var grantCarrier = Harc_V1_ExactSignedObjectV1()
        grantCarrier.framedBytes = historicalGrantObject.exactFramedBytes
        historicalDevice.exactSignedDeviceGrants = [grantCarrier]
        var revocationCarrier = Harc_V1_ExactSignedObjectV1()
        revocationCarrier.framedBytes = revocationObject.exactFramedBytes
        historicalDevice.exactSignedDeviceRevocations = [revocationCarrier]
        history.devices = [historicalDevice]
        let historyObject = try signedObject(
            messageType: .portableTrustHistory,
            payloadType: .portableTrustHistory,
            payload: history.serializedData(),
            libraryID: libraryID,
            authorityID: authorityID,
            operationID: exportID,
            issuedAt: issuedAt,
            signer: hostKey
        )
        guard case .portableTrustHistory = try historyObject
            .authenticateRegisteredPayload(
                using: hostKey.publicKey,
                purpose: .historicalEvidence
            ).payload else {
            Issue.record("Expected portable trust history payload")
            return
        }
    }

    private func grantFixture() throws -> (
        hostKey: SoftwareP256SigningKey,
        deviceKey: SoftwareP256SigningKey,
        libraryID: LibraryID,
        grantID: UUID,
        wire: Harc_V1_DeviceGrantV1,
        payload: Data,
        object: HarcSignedObjectV1
    ) {
        let hostKey = ProtocolCodecFixtures.key(61)
        let deviceKey = ProtocolCodecFixtures.key(62)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(610))
        let grantID = ProtocolCodecFixtures.uuid(611)
        var wire = Harc_V1_DeviceGrantV1()
        wire.protocol = wireProtocol()
        wire.libraryID = Harc_V1_LibraryIDV1(libraryID)
        wire.hostAuthorityID = Harc_V1_HostAuthorityIDV1(hostKey.publicKey.hostAuthorityID)
        wire.grantID.value = uuidBytes(grantID)
        wire.deviceID = Harc_V1_DeviceIDV1(deviceKey.publicKey.deviceID)
        wire.devicePublicKeyX963 = deviceKey.publicKey.rawBytes
        wire.scopes = [.authorizationScopeRecordingReadOwn]
        wire.grantEpoch = 1
        wire.issuedAtUnixMs = ProtocolCodecFixtures.issuedAt
        wire.minimumCompatibleProtocolMinor = 0
        wire.maximumCompatibleProtocolMinor = 0
        let payload = try wire.serializedData()
        let header = try HarcSignedEnvelopeV1(
            messageType: .deviceGrant,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: grantID,
            grantEpoch: 1,
            operationID: nil,
            issuedAtUnixMilliseconds: ProtocolCodecFixtures.issuedAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .deviceGrant,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: hostKey
        )
        return (hostKey, deviceKey, libraryID, grantID, wire, payload, object)
    }

    private func wireProtocol() -> Harc_V1_ProtocolVersionV1 {
        HarcProtocolVersion.v1.protobufV1()
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
        expectedRevision: UInt64? = nil,
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
            expectedRevision: expectedRevision,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        return try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: signer
        )
    }

    private func origin(
        deviceID: DeviceID,
        recordingUUID: UUID
    ) -> Harc_V1_OriginRecordingIDV1 {
        var value = Harc_V1_OriginRecordingIDV1()
        value.deviceID = Harc_V1_DeviceIDV1(deviceID)
        value.recordingUuid = uuidBytes(recordingUUID)
        return value
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

    private func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
