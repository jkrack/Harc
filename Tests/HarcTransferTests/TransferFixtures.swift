import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcTransfer

enum TransferFixtures {
    static let baseDate = Date(timeIntervalSince1970: 2_000_000_000)

    static func bytes(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    static func signingKey(_ byte: UInt8 = 1) -> SoftwareP256SigningKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = byte == 0 ? 1 : byte
        return try! SoftwareP256SigningKey(rawRepresentation: scalar)
    }

    static func device(_ byte: UInt8 = 1) -> DeviceID {
        signingKey(byte).publicKey.deviceID
    }

    static func origin(deviceByte: UInt8 = 1, recording: UInt32 = 1) -> OriginRecordingID {
        OriginRecordingID(
            deviceID: device(deviceByte),
            recordingUUID: uuid(recording)
        )
    }

    static func uuid(_ value: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012u", value))!
    }

    static func profile(
        encoding: LosslessEncodingConfiguration = .cafALAC,
        purpose: UploadProfilePurpose = .production,
        hashByte: UInt8 = 20
    ) -> FrozenUploadProfile {
        try! FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: encoding,
            requiredCapabilities: [try! TransferCapabilityID("transfer.chunk.v1")],
            negotiatedCapabilitiesSHA256: try! NegotiatedCapabilitiesSHA256(bytes(19)),
            profileSHA256: try! UploadProfileSHA256(bytes(hashByte)),
            purpose: purpose
        )
    }

    static func capture(
        origin: OriginRecordingID = origin(),
        frames: UInt64 = 1_200_000,
        discontinuities: [CaptureDiscontinuity] = []
    ) -> FinalizedCapture {
        try! FinalizedCapture(
            producingDeviceID: origin.deviceID,
            originRecordingID: origin,
            captureStartedAt: baseDate,
            captureEndedAt: baseDate.addingTimeInterval(75),
            captureStartedMonotonicNanoseconds: 1_000,
            captureEndedMonotonicNanoseconds: 75_000_001_000,
            finalizationReason: .userStopped,
            totalCanonicalFrames: frames,
            totalCanonicalBytes: frames * 2,
            canonicalPCMSHA256: try! CanonicalPCMHash(bytes(2)),
            discontinuities: discontinuities
        )
    }

    static func chunk(
        origin: OriginRecordingID = origin(),
        index: UInt32,
        startFrame: UInt64,
        frameCount: UInt64,
        id: UInt32? = nil,
        encoding: LosslessEncodingConfiguration = .cafALAC,
        hashByte: UInt8? = nil
    ) -> LogicalChunkDescriptor {
        let byte = hashByte ?? UInt8(truncatingIfNeeded: index &+ 30)
        let decoded = try! CanonicalPCMHash(bytes(byte))
        let encoded = encoding == .rawPCMFixture
            ? try! EncodedChunkSHA256(decoded.rawBytes)
            : try! EncodedChunkSHA256(bytes(byte &+ 50))
        let decodedBytes = frameCount * 2
        return try! LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(uuid(id ?? index &+ 100)),
            chunkIndex: index,
            canonicalStartFrame: startFrame,
            canonicalFrameCount: frameCount,
            encoding: encoding,
            encodedByteLength: encoding == .rawPCMFixture ? decodedBytes : max(1, decodedBytes / 2),
            encodedSHA256: encoded,
            canonicalDecodedByteLength: decodedBytes,
            canonicalDecodedSHA256: decoded
        )
    }

    static func chunkedCapture(
        origin: OriginRecordingID = origin(),
        encoding: LosslessEncodingConfiguration = .cafALAC
    ) -> ChunkedFinalizedCapture {
        let capture = capture(origin: origin)
        return try! ChunkedFinalizedCapture(
            capture: capture,
            chunks: [
                chunk(origin: origin, index: 0, startFrame: 0, frameCount: 960_000, encoding: encoding),
                chunk(origin: origin, index: 1, startFrame: 960_000, frameCount: 240_000, encoding: encoding),
            ]
        )
    }

    static func exactObject(_ kind: ExactObjectKind, byte: UInt8) -> OpaqueExactObjectSlot {
        try! OpaqueExactObjectSlot(
            kind: kind,
            exactBytes: Data([byte, byte &+ 1, byte &+ 2]),
            objectSHA256: try! ExactObjectSHA256(bytes(byte))
        )
    }

    static func hostTrust(
        library: UInt32 = 700,
        authorityKeyByte: UInt8 = 200
    ) -> RecordingHostTrustBinding {
        let publicKey = signingKey(authorityKeyByte).publicKey
        return try! RecordingHostTrustBinding(
            libraryID: LibraryID(uuid(library)),
            hostAuthorityID: publicKey.hostAuthorityID,
            hostAuthorityPublicKey: publicKey
        )
    }

    static func manifestEvidence(
        uploadID: UploadID,
        finalizedCapture: ChunkedFinalizedCapture,
        profile: FrozenUploadProfile = profile(),
        trust: RecordingHostTrustBinding = hostTrust(),
        manifestByte: UInt8 = 8,
        producingKeyByte: UInt8 = 1
    ) -> ValidatedRecordingManifestEvidence {
        try! ValidatedRecordingManifestEvidence(
            hostTrust: trust,
            exactManifestObject: exactObject(.recordingManifestV1, byte: manifestByte),
            uploadID: uploadID,
            producingDevicePublicKey: signingKey(producingKeyByte).publicKey,
            originRecordingID: finalizedCapture.capture.originRecordingID,
            uploadProfileSHA256: profile.profileSHA256,
            finalizedCapture: finalizedCapture
        )
    }

    static func receiptEvidence(
        manifest: ValidatedRecordingManifestEvidence,
        receiptByte: UInt8 = 9
    ) -> ValidatedRecordingReceiptEvidence {
        try! makeReceiptEvidence(manifest: manifest, receiptByte: receiptByte)
    }

    static func makeReceiptEvidence(
        manifest: ValidatedRecordingManifestEvidence,
        receiptByte: UInt8 = 9,
        hostTrust: RecordingHostTrustBinding? = nil,
        uploadID: UploadID? = nil,
        originRecordingID: OriginRecordingID? = nil,
        signedManifestObjectSHA256: ExactObjectSHA256? = nil,
        canonicalPCMSHA256: CanonicalPCMHash? = nil,
        totalCanonicalFrames: UInt64? = nil,
        canonicalFormat: CanonicalPCMFormat? = nil
    ) throws -> ValidatedRecordingReceiptEvidence {
        try ValidatedRecordingReceiptEvidence(
            hostTrust: hostTrust ?? manifest.hostTrust,
            exactReceiptObject: exactObject(.recordingReceiptV1, byte: receiptByte),
            validatedManifest: manifest,
            uploadID: uploadID ?? manifest.uploadID,
            originRecordingID: originRecordingID ?? manifest.originRecordingID,
            signedManifestObjectSHA256: signedManifestObjectSHA256
                ?? manifest.exactManifestObject.objectSHA256,
            canonicalPCMSHA256: canonicalPCMSHA256 ?? manifest.canonicalPCMSHA256,
            totalCanonicalFrames: totalCanonicalFrames ?? manifest.totalCanonicalFrames,
            canonicalFormat: canonicalFormat ?? manifest.canonicalFormat,
            canonicalRecordingID: CanonicalRecordingID(uuid(800)),
            canonicalRevision: .initial,
            changeCursor: ChangeCursor(1),
            receiptID: uuid(801),
            durableCommitTime: baseDate.addingTimeInterval(10),
            processingState: .pending
        )
    }
}
