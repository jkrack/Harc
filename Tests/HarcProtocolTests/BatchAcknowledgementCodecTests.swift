import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
@testable import HarcTransfer
import Testing

@Suite("Exact background batch acknowledgement evidence")
struct BatchAcknowledgementCodecTests {
    @Test("issuer and validator preserve one fully bound exact ACK")
    func issueValidateAndReplay() throws {
        let fixture = try Fixture()
        let claims = try BatchAcknowledgementClaims(
            hostTrust: fixture.hostTrust,
            batch: fixture.batch,
            acknowledgementID: fixture.acknowledgementID,
            durableAt: fixture.durableAt
        )
        let issued = try fixture.codec.issueBatchAcknowledgement(
            claims: claims,
            hostAuthoritySigner: fixture.hostKey
        )

        #expect(issued.exactAcknowledgementObject.kind == .audioBatchAckV1)
        #expect(issued.hostTrust == fixture.hostTrust)
        #expect(issued.batchID == fixture.batch.batchID)
        #expect(issued.uploadID == fixture.batch.uploadID)
        #expect(issued.ownerDeviceID == fixture.batch.ownerDeviceID)
        #expect(issued.exactBatchBodySHA256 == fixture.batch.exactBodySHA256)
        #expect(issued.durableChunks == fixture.expectedDurableChunks)
        #expect(issued.acknowledgementID == fixture.acknowledgementID)
        #expect(issued.durableAt == fixture.durableAt)

        let first = try fixture.codec.validateBatchAcknowledgement(
            exactSignedAcknowledgementBytes: issued.exactAcknowledgementObject.exactBytes,
            batch: fixture.batch,
            hostTrust: fixture.hostTrust
        )
        let replay = try fixture.codec.validateBatchAcknowledgement(
            exactSignedAcknowledgementBytes: issued.exactAcknowledgementObject.exactBytes,
            batch: fixture.batch,
            hostTrust: fixture.hostTrust
        )
        #expect(first == issued)
        #expect(replay == first)
        #expect(
            first.exactAcknowledgementObject.exactBytes
                == issued.exactAcknowledgementObject.exactBytes
        )

        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            issued.exactAcknowledgementObject.exactBytes,
            using: fixture.hostKey.publicKey,
            purpose: .historicalEvidence
        )
        guard case .batchAcknowledgement(let exactPayload) = authenticated.payload else {
            Issue.record("Expected a batch acknowledgement payload")
            return
        }
        #expect(exactPayload.message.issuedAtUnixMs == Fixture.durableMilliseconds)
        #expect(exactPayload.message.durableAtUnixMs == Fixture.durableMilliseconds)
        #expect(exactPayload.message.acceptedChunks.count == fixture.batch.chunks.count)
    }

    @Test("issuer rejects an authority signer from another adoption")
    func issuerRejectsWrongSigner() throws {
        let fixture = try Fixture()
        let claims = try BatchAcknowledgementClaims(
            hostTrust: fixture.hostTrust,
            batch: fixture.batch,
            acknowledgementID: fixture.acknowledgementID,
            durableAt: fixture.durableAt
        )
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "batchAcknowledgement.hostAuthoritySigner"
        )) {
            try fixture.codec.issueBatchAcknowledgement(
                claims: claims,
                hostAuthoritySigner: ProtocolCodecFixtures.key(0xb7)
            )
        }
    }

    @Test("validator rejects a valid ACK against a different immutable body")
    func validatorRejectsDifferentBody() throws {
        let fixture = try Fixture()
        let issued = try fixture.issue()
        let otherBatch = try fixture.batchWithBodyHash(0x7f)

        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "batchAcknowledgement.exactBatchBodySHA256"
        )) {
            try fixture.codec.validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes: issued.exactAcknowledgementObject.exactBytes,
                batch: otherBatch,
                hostTrust: fixture.hostTrust
            )
        }
    }

    @Test("validator rejects authority-signed accepted-chunk substitution")
    func validatorRejectsAcceptedChunkSubstitution() throws {
        let fixture = try Fixture()
        let issued = try fixture.issue()
        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            issued.exactAcknowledgementObject.exactBytes,
            using: fixture.hostKey.publicKey,
            purpose: .historicalEvidence
        )
        guard case .batchAcknowledgement(let exactPayload) = authenticated.payload else {
            Issue.record("Expected a batch acknowledgement payload")
            return
        }
        var value = exactPayload.message
        value.acceptedChunks[0].encodedSha256.value = Fixture.digest(0xee)
        let substituted = try fixture.sign(value)

        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "batchAcknowledgement.acceptedChunks"
        )) {
            try fixture.codec.validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes: substituted.exactFramedBytes,
                batch: fixture.batch,
                hostTrust: fixture.hostTrust
            )
        }
    }

    @Test("signature failure is rejected before ACK payload authority")
    func validatorRejectsTamperedSignature() throws {
        let fixture = try Fixture()
        let issued = try fixture.issue()
        var tampered = issued.exactAcknowledgementObject.exactBytes
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01

        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try fixture.codec.validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes: tampered,
                batch: fixture.batch,
                hostTrust: fixture.hostTrust
            )
        }
    }
}

private struct Fixture {
    static let durableMilliseconds: UInt64 = 2_000_000_123_000

    let hostKey = ProtocolCodecFixtures.key(0xb1)
    let deviceKey = ProtocolCodecFixtures.key(0xb2)
    let codec = HarcBatchAcknowledgementCodecV1()
    let acknowledgementID = ProtocolCodecFixtures.uuid(8_006)
    let durableAt = Date(
        timeIntervalSince1970: Double(durableMilliseconds) / 1_000
    )
    let hostTrust: RecordingHostTrustBinding
    let batch: ImmutableAudioBatchDescriptor

    init() throws {
        hostTrust = try RecordingHostTrustBinding(
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(8_001)),
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey
        )
        let origin = OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: ProtocolCodecFixtures.uuid(8_002)
        )
        let chunks = try [
            Self.chunk(origin: origin, index: 0, start: 0, hashByte: 0x31),
            Self.chunk(origin: origin, index: 1, start: 160, hashByte: 0x32),
        ]
        batch = try ImmutableAudioBatchDescriptor(
            batchID: AudioBatchID(ProtocolCodecFixtures.uuid(8_003)),
            uploadID: UploadID(ProtocolCodecFixtures.uuid(8_004)),
            generation: .initial,
            uploadProfileSHA256: UploadProfileSHA256(Self.digest(0x33)),
            originRecordingID: origin,
            ownerDeviceID: deviceKey.publicKey.deviceID,
            chunks: chunks,
            exactBodyByteLength: 512,
            exactBodySHA256: ImmutableBatchSHA256(Self.digest(0x34))
        )
    }

    var expectedDurableChunks: [DurableChunkStatus] {
        batch.chunks.map {
            DurableChunkStatus(
                chunkIndex: $0.chunkIndex,
                chunkID: $0.chunkID,
                encodedSHA256: $0.encodedSHA256
            )
        }
    }

    func issue() throws -> ValidatedBatchAcknowledgementEvidence {
        try codec.issueBatchAcknowledgement(
            claims: BatchAcknowledgementClaims(
                hostTrust: hostTrust,
                batch: batch,
                acknowledgementID: acknowledgementID,
                durableAt: durableAt
            ),
            hostAuthoritySigner: hostKey
        )
    }

    func batchWithBodyHash(_ byte: UInt8) throws -> ImmutableAudioBatchDescriptor {
        try ImmutableAudioBatchDescriptor(
            batchID: batch.batchID,
            uploadID: batch.uploadID,
            generation: batch.generation,
            uploadProfileSHA256: batch.uploadProfileSHA256,
            originRecordingID: batch.originRecordingID,
            ownerDeviceID: batch.ownerDeviceID,
            chunks: batch.chunks,
            exactBodyByteLength: batch.exactBodyByteLength,
            exactBodySHA256: ImmutableBatchSHA256(Self.digest(byte))
        )
    }

    func sign(_ value: Harc_V1_BatchAckV1) throws -> HarcSignedObjectV1 {
        let exactPayload = try HarcExactProtobufPayload(serializingOnce: value)
        let header = try HarcSignedEnvelopeV1(
            messageType: .batchAcknowledgement,
            libraryID: hostTrust.libraryID,
            hostAuthorityID: hostTrust.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: batch.batchID.rawValue,
            issuedAtUnixMilliseconds: value.issuedAtUnixMs,
            expiresAtUnixMilliseconds: nil,
            payloadType: .batchAcknowledgement,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload.exactBytes)
        )
        return try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: exactPayload.exactBytes,
            payloadBindings: HarcSignedPayloadBindingsV1(
                protocolVersion: .v1,
                libraryID: hostTrust.libraryID,
                hostAuthorityID: hostTrust.hostAuthorityID,
                issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                operationID: batch.batchID.rawValue
            ),
            using: hostKey
        )
    }

    static func chunk(
        origin: OriginRecordingID,
        index: UInt32,
        start: UInt64,
        hashByte: UInt8
    ) throws -> LogicalChunkDescriptor {
        try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(ProtocolCodecFixtures.uuid(8_100 + index)),
            chunkIndex: index,
            canonicalStartFrame: start,
            canonicalFrameCount: 160,
            encoding: .cafALAC,
            encodedByteLength: 100,
            encodedSHA256: EncodedChunkSHA256(digest(hashByte)),
            canonicalDecodedByteLength: 320,
            canonicalDecodedSHA256: CanonicalPCMHash(digest(hashByte &+ 0x20))
        )
    }

    static func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }
}
