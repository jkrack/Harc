import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
@testable import HarcTransfer
import SwiftProtobuf
import Testing

@Suite("Exact recording manifest and receipt evidence")
struct RecordingEvidenceCodecTests {
    @Test("device-signed manifest authenticates into exact transfer evidence")
    func manifestValidationPreservesExactBytes() throws {
        let fixture = try Fixture()
        let evidence = try fixture.codec.validateRecordingManifest(
            exactSignedManifestBytes: fixture.manifestObject.exactFramedBytes,
            hostTrust: fixture.hostTrust,
            producingDevicePublicKey: fixture.deviceKey.publicKey
        )

        #expect(evidence.exactManifestObject.exactBytes == fixture.manifestObject.exactFramedBytes)
        #expect(evidence.exactManifestObject.objectSHA256 == fixture.manifestObject.objectID)
        #expect(evidence.hostTrust == fixture.hostTrust)
        #expect(evidence.uploadID.rawValue == fixture.manifest.uploadIDValue)
        #expect(evidence.originRecordingID == fixture.origin)
        #expect(evidence.producingDeviceID == fixture.deviceKey.publicKey.deviceID)
        #expect(evidence.canonicalPCMSHA256.rawBytes == fixture.manifest.canonicalPcmSha256.value)
        #expect(evidence.totalCanonicalFrames == fixture.manifest.totalCanonicalFrames)

        let wrongLibraryTrust = try RecordingHostTrustBinding(
            libraryID: LibraryID(ProtocolCodecFixtures.uuid(7_099)),
            hostAuthorityID: fixture.hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: fixture.hostKey.publicKey
        )
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "libraryID")) {
            try fixture.codec.validateRecordingManifest(
                exactSignedManifestBytes: fixture.manifestObject.exactFramedBytes,
                hostTrust: wrongLibraryTrust,
                producingDevicePublicKey: fixture.deviceKey.publicKey
            )
        }
        #expect(throws: Error.self) {
            try fixture.codec.validateRecordingManifest(
                exactSignedManifestBytes: fixture.manifestObject.exactFramedBytes,
                hostTrust: fixture.hostTrust,
                producingDevicePublicKey: ProtocolCodecFixtures.key(0x63).publicKey
            )
        }
        var tampered = fixture.manifestObject.exactFramedBytes
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        #expect(throws: Error.self) {
            try fixture.codec.validateRecordingManifest(
                exactSignedManifestBytes: tampered,
                hostTrust: fixture.hostTrust,
                producingDevicePublicKey: fixture.deviceKey.publicKey
            )
        }
    }

    @Test("recording manifests reject unknown descriptor semantics")
    func manifestRejectsUnknownDescriptorFields() throws {
        let fixture = try Fixture()
        let object = try fixture.signedManifest { manifest in
            let exact = try manifest.chunks[0].serializedData()
                + Data([0xa0, 0x06, 0x01])
            manifest.chunks[0] = try Harc_V1_ChunkDescriptorV1(
                serializedBytes: exact
            )
        }
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "chunkDescriptor.unknownFields"
        )) {
            try fixture.codec.validateRecordingManifest(
                exactSignedManifestBytes: object.exactFramedBytes,
                hostTrust: fixture.hostTrust,
                producingDevicePublicKey: fixture.deviceKey.publicKey
            )
        }
    }

    @Test("issuer emits a current pending receipt and validator preserves exact replay bytes")
    func receiptIssueValidateAndReplay() throws {
        let fixture = try Fixture()
        let manifestEvidence = try fixture.validatedManifest()
        let claims = try fixture.claims(manifestEvidence)
        let issued = try fixture.codec.issueRecordingReceipt(
            claims: claims,
            hostAuthoritySigner: fixture.hostKey
        )
        #expect(issued.kind == .recordingReceiptV1)

        let authenticated = try HarcAuthenticatedSignedObjectV1.decodeAndAuthenticate(
            issued.exactBytes,
            using: fixture.hostKey.publicKey,
            purpose: .historicalEvidence
        )
        guard case .recordingReceipt(let exactPayload) = authenticated.payload else {
            Issue.record("Expected recording receipt payload")
            return
        }
        let receipt = exactPayload.message
        #expect(receipt.protocol.major == 1)
        #expect(receipt.protocol.minor == 0)
        #expect(receipt.processingState == .recordingProcessingStatePending)
        #expect(receipt.issuedAtUnixMs == Fixture.durableAt)
        #expect(receipt.signedManifestObjectSha256.value == manifestEvidence.exactManifestObject.objectSHA256.rawBytes)

        let first = try fixture.codec.validateRecordingReceipt(
            exactSignedReceiptBytes: issued.exactBytes,
            validatedManifest: manifestEvidence,
            hostTrust: fixture.hostTrust
        )
        let replay = try fixture.codec.validateRecordingReceipt(
            exactSignedReceiptBytes: issued.exactBytes,
            validatedManifest: manifestEvidence,
            hostTrust: fixture.hostTrust
        )
        #expect(first == replay)
        #expect(first.exactReceiptObject == issued)
        #expect(first.exactReceiptObject.exactBytes == issued.exactBytes)
        #expect(first.exactReceiptObject.objectSHA256 == issued.objectSHA256)
        #expect(first.exactManifestObject == manifestEvidence.exactManifestObject)
        #expect(first.processingState == .pending)
        #expect(first.canonicalRecordingID == claims.canonicalRecordingID)
        #expect(first.canonicalRevision == claims.canonicalRevision)
        #expect(first.changeCursor == claims.changeCursor)
        #expect(first.receiptID == claims.receiptID)
        #expect(first.durableCommitTime == claims.durableCommitTime)

        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "hostAuthoritySigner"
        )) {
            try fixture.codec.issueRecordingReceipt(
                claims: claims,
                hostAuthoritySigner: ProtocolCodecFixtures.key(0x64)
            )
        }
    }

    @Test("receipt signature failure precedes malformed protobuf interpretation")
    func receiptSignaturePrecedesPayloadDecode() throws {
        let fixture = try Fixture()
        let manifestEvidence = try fixture.validatedManifest()
        let malformedPayload = Data([0xff])
        let header = try HarcSignedEnvelopeV1(
            messageType: .recordingReceipt,
            libraryID: fixture.hostTrust.libraryID,
            hostAuthorityID: fixture.hostTrust.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: manifestEvidence.uploadID.rawValue,
            issuedAtUnixMilliseconds: Fixture.durableAt,
            expiresAtUnixMilliseconds: nil,
            payloadType: .recordingReceipt,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(malformedPayload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: malformedPayload,
            using: fixture.hostKey
        )
        var invalidSignature = object.exactFramedBytes
        invalidSignature[invalidSignature.index(before: invalidSignature.endIndex)] ^= 0x01

        #expect(throws: HarcProtocolCodecError.invalidSignature) {
            try fixture.codec.validateRecordingReceipt(
                exactSignedReceiptBytes: invalidSignature,
                validatedManifest: manifestEvidence,
                hostTrust: fixture.hostTrust
            )
        }
    }

    @Test("validator rejects valid host signatures over wrong host, origin, upload, manifest, or audio")
    func receiptEqualityChecks() throws {
        let fixture = try Fixture()
        let manifestEvidence = try fixture.validatedManifest()

        let wrongLibrary = try fixture.signedReceipt { value in
            value.libraryID = Harc_V1_LibraryIDV1(
                LibraryID(ProtocolCodecFixtures.uuid(7_101))
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "libraryID")) {
            try fixture.validate(wrongLibrary, manifest: manifestEvidence)
        }

        let wrongHostKey = ProtocolCodecFixtures.key(0x62)
        let wrongHost = try fixture.signedReceipt(signingKey: wrongHostKey) { value in
            value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
                wrongHostKey.publicKey.hostAuthorityID
            )
        }
        #expect(throws: Error.self) {
            try fixture.validate(wrongHost, manifest: manifestEvidence)
        }

        let otherDevice = ProtocolCodecFixtures.key(0x61).publicKey.deviceID
        let wrongDevice = try fixture.signedReceipt { value in
            value.producingDeviceID = Harc_V1_DeviceIDV1(otherDevice)
            value.originRecordingID = Harc_V1_OriginRecordingIDV1(
                OriginRecordingID(
                    deviceID: otherDevice,
                    recordingUUID: ProtocolCodecFixtures.uuid(7_102)
                )
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "producingDeviceID"
        )) {
            try fixture.validate(wrongDevice, manifest: manifestEvidence)
        }

        let wrongOrigin = try fixture.signedReceipt { value in
            value.originRecordingID = Harc_V1_OriginRecordingIDV1(
                OriginRecordingID(
                    deviceID: fixture.deviceKey.publicKey.deviceID,
                    recordingUUID: ProtocolCodecFixtures.uuid(7_103)
                )
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "originRecordingID"
        )) {
            try fixture.validate(wrongOrigin, manifest: manifestEvidence)
        }

        let wrongUpload = try fixture.signedReceipt { value in
            value.uploadID = Harc_V1_UploadIDV1(
                UploadID(ProtocolCodecFixtures.uuid(7_104))
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "uploadID")) {
            try fixture.validate(wrongUpload, manifest: manifestEvidence)
        }

        let wrongManifest = try fixture.signedReceipt { value in
            value.signedManifestObjectSha256.value = Fixture.digest(0xa1)
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "signedManifestObjectSHA256"
        )) {
            try fixture.validate(wrongManifest, manifest: manifestEvidence)
        }

        let wrongAudio = try fixture.signedReceipt { value in
            value.canonicalPcmSha256.value = Fixture.digest(0xa2)
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "canonicalPCMSHA256"
        )) {
            try fixture.validate(wrongAudio, manifest: manifestEvidence)
        }

        let wrongFrames = try fixture.signedReceipt { value in
            value.totalCanonicalFrames += 1
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "totalCanonicalFrames"
        )) {
            try fixture.validate(wrongFrames, manifest: manifestEvidence)
        }

        let wrongFormat = try fixture.signedReceipt { value in
            value.canonicalFormat.sampleRateHz = 48_000
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "canonicalFormat"
        )) {
            try fixture.validate(wrongFormat, manifest: manifestEvidence)
        }
    }

    @Test("validator rejects zero canonical identities, cursors, times, non-pending state, and non-current protocol")
    func receiptStrictScalarChecks() throws {
        let fixture = try Fixture()
        let manifestEvidence = try fixture.validatedManifest()

        let zeroCanonicalID = try fixture.signedReceipt { value in
            value.canonicalRecordingID.value = Data(repeating: 0, count: 16)
        }
        #expect(throws: Error.self) {
            try fixture.validate(zeroCanonicalID, manifest: manifestEvidence)
        }
        let zeroRevision = try fixture.signedReceipt { $0.canonicalRecordingRevision = 0 }
        #expect(throws: Error.self) {
            try fixture.validate(zeroRevision, manifest: manifestEvidence)
        }
        let zeroCursor = try fixture.signedReceipt { $0.changeCursor = 0 }
        #expect(throws: Error.self) {
            try fixture.validate(zeroCursor, manifest: manifestEvidence)
        }
        let zeroReceiptID = try fixture.signedReceipt { value in
            value.receiptID.value = Data(repeating: 0, count: 16)
        }
        #expect(throws: Error.self) {
            try fixture.validate(zeroReceiptID, manifest: manifestEvidence)
        }
        let zeroTime = try fixture.signedReceipt { $0.issuedAtUnixMs = 0 }
        #expect(throws: Error.self) {
            try fixture.validate(zeroTime, manifest: manifestEvidence)
        }
        let ready = try fixture.signedReceipt {
            $0.processingState = .recordingProcessingStateReady
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "processingState"
        )) {
            try fixture.validate(ready, manifest: manifestEvidence)
        }
        let futureMinor = try fixture.signedReceipt { value in
            value.protocol.minor = 1
        }
        #expect(throws: HarcProtocolCodecError.unsupportedProtocolMinor(1)) {
            try fixture.validate(futureMinor, manifest: manifestEvidence)
        }
    }

    private struct Fixture {
        static let durableAt = ProtocolCodecFixtures.issuedAt + 10_000

        let codec = HarcRecordingEvidenceCodecV1()
        let hostKey = ProtocolCodecFixtures.key(0x51)
        let deviceKey = ProtocolCodecFixtures.key(0x52)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(7_001))
        let origin: OriginRecordingID
        let hostTrust: RecordingHostTrustBinding
        let manifest: Harc_V1_RecordingManifestV1
        let manifestObject: HarcSignedObjectV1

        init() throws {
            origin = OriginRecordingID(
                deviceID: deviceKey.publicKey.deviceID,
                recordingUUID: ProtocolCodecFixtures.uuid(7_002)
            )
            hostTrust = try RecordingHostTrustBinding(
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                hostAuthorityPublicKey: hostKey.publicKey
            )
            manifest = Self.makeManifest(
                libraryID: libraryID,
                authorityID: hostKey.publicKey.hostAuthorityID,
                deviceID: deviceKey.publicKey.deviceID,
                origin: origin
            )
            manifestObject = try Self.signManifest(
                manifest,
                libraryID: libraryID,
                authorityID: hostKey.publicKey.hostAuthorityID,
                deviceKey: deviceKey
            )
        }

        func validatedManifest() throws -> ValidatedRecordingManifestEvidence {
            try codec.validateRecordingManifest(
                exactSignedManifestBytes: manifestObject.exactFramedBytes,
                hostTrust: hostTrust,
                producingDevicePublicKey: deviceKey.publicKey
            )
        }

        func claims(
            _ manifest: ValidatedRecordingManifestEvidence
        ) throws -> RecordingReceiptClaims {
            try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(
                    ProtocolCodecFixtures.uuid(7_010)
                ),
                canonicalRevision: EntityRevision(2),
                changeCursor: ChangeCursor(3),
                receiptID: ProtocolCodecFixtures.uuid(7_011),
                durableCommitTime: Date(
                    timeIntervalSince1970: Double(Self.durableAt) / 1_000
                )
            )
        }

        func validate(
            _ object: HarcSignedObjectV1,
            manifest: ValidatedRecordingManifestEvidence
        ) throws -> ValidatedRecordingReceiptEvidence {
            try codec.validateRecordingReceipt(
                exactSignedReceiptBytes: object.exactFramedBytes,
                validatedManifest: manifest,
                hostTrust: hostTrust
            )
        }

        func signedReceipt(
            signingKey: SoftwareP256SigningKey? = nil,
            mutate: (inout Harc_V1_RecordingReceiptV1) -> Void = { _ in }
        ) throws -> HarcSignedObjectV1 {
            let manifest = try validatedManifest()
            var value = Self.baseReceipt(manifest: manifest)
            mutate(&value)
            let payload = try value.serializedData()
            let version = HarcProtocolVersion(
                major: UInt16(value.protocol.major),
                minor: UInt16(value.protocol.minor)
            )
            let policy = HarcProtocolVersionPolicy(
                major: version.major,
                supportedMinorRange: 0 ... max(1, version.minor)
            )
            let header = try HarcSignedEnvelopeV1(
                messageType: .recordingReceipt,
                protocolVersion: version,
                libraryID: try value.libraryID.domainValue(),
                hostAuthorityID: try value.hostAuthorityID.domainValue(),
                signerDeviceID: nil,
                grantID: nil,
                grantEpoch: 0,
                operationID: try value.uploadID.domainValue().rawValue,
                issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                expiresAtUnixMilliseconds: nil,
                payloadType: .recordingReceipt,
                expectedRevision: nil,
                payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload),
                versionPolicy: policy
            )
            return try HarcSignedObjectV1.sign(
                header: header,
                exactPayloadBytes: payload,
                using: signingKey ?? hostKey
            )
        }

        func signedManifest(
            mutate: (inout Harc_V1_RecordingManifestV1) throws -> Void
        ) throws -> HarcSignedObjectV1 {
            var value = manifest
            try mutate(&value)
            return try Self.signManifest(
                value,
                libraryID: libraryID,
                authorityID: hostKey.publicKey.hostAuthorityID,
                deviceKey: deviceKey
            )
        }

        private static func makeManifest(
            libraryID: LibraryID,
            authorityID: HostAuthorityID,
            deviceID: DeviceID,
            origin: OriginRecordingID
        ) -> Harc_V1_RecordingManifestV1 {
            var value = Harc_V1_RecordingManifestV1()
            value.protocol = HarcProtocolVersion.v1.protobufV1()
            value.manifestVersion = 1
            value.issuedAtUnixMs = ProtocolCodecFixtures.issuedAt
            value.libraryID = Harc_V1_LibraryIDV1(libraryID)
            value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(authorityID)
            value.originRecordingID = Harc_V1_OriginRecordingIDV1(origin)
            value.uploadID = Harc_V1_UploadIDV1(
                UploadID(ProtocolCodecFixtures.uuid(7_003))
            )
            value.producingDeviceID = Harc_V1_DeviceIDV1(deviceID)
            value.uploadProfileSha256.value = digest(0x71)
            value.descriptorSchemaID = ChunkDescriptorSchema.v1.rawValue
            value.encoding = alacEncoding()
            value.captureStartedAtUnixMs = ProtocolCodecFixtures.issuedAt - 5_000
            value.captureEndedAtUnixMs = ProtocolCodecFixtures.issuedAt - 1
            value.captureStartedMonotonicNanoseconds = 100
            value.captureEndedMonotonicNanoseconds = 200
            value.finalizationReason = .captureFinalizationReasonUserStopped
            value.canonicalFormat = canonicalFormat()
            value.totalCanonicalFrames = 2
            value.totalCanonicalBytes = 4
            value.canonicalPcmSha256.value = digest(0x72)
            var chunk = Harc_V1_ChunkDescriptorV1()
            chunk.originRecordingID = value.originRecordingID
            chunk.chunkID.value = uuidBytes(ProtocolCodecFixtures.uuid(7_004))
            chunk.chunkIndex = 0
            chunk.canonicalStartFrame = 0
            chunk.canonicalFrameCount = 2
            chunk.canonicalFormat = canonicalFormat()
            chunk.encoding = alacEncoding()
            chunk.encodedByteLength = 3
            chunk.encodedSha256.value = digest(0x73)
            chunk.canonicalDecodedByteLength = 4
            chunk.canonicalDecodedSha256.value = digest(0x72)
            value.chunks = [chunk]
            return value
        }

        private static func signManifest(
            _ value: Harc_V1_RecordingManifestV1,
            libraryID: LibraryID,
            authorityID: HostAuthorityID,
            deviceKey: SoftwareP256SigningKey
        ) throws -> HarcSignedObjectV1 {
            let payload = try value.serializedData()
            let header = try HarcSignedEnvelopeV1(
                messageType: .recordingManifest,
                libraryID: libraryID,
                hostAuthorityID: authorityID,
                signerDeviceID: deviceKey.publicKey.deviceID,
                grantID: nil,
                grantEpoch: 0,
                operationID: try value.uploadID.domainValue().rawValue,
                issuedAtUnixMilliseconds: value.issuedAtUnixMs,
                expiresAtUnixMilliseconds: nil,
                payloadType: .recordingManifest,
                expectedRevision: nil,
                payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
            )
            return try HarcSignedObjectV1.sign(
                header: header,
                exactPayloadBytes: payload,
                using: deviceKey
            )
        }

        private static func baseReceipt(
            manifest: ValidatedRecordingManifestEvidence
        ) -> Harc_V1_RecordingReceiptV1 {
            var value = Harc_V1_RecordingReceiptV1()
            value.protocol = HarcProtocolVersion.v1.protobufV1()
            value.libraryID = Harc_V1_LibraryIDV1(manifest.hostTrust.libraryID)
            value.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
                manifest.hostTrust.hostAuthorityID
            )
            value.producingDeviceID = Harc_V1_DeviceIDV1(manifest.producingDeviceID)
            value.originRecordingID = Harc_V1_OriginRecordingIDV1(manifest.originRecordingID)
            value.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
                CanonicalRecordingID(ProtocolCodecFixtures.uuid(7_010))
            )
            value.uploadID = Harc_V1_UploadIDV1(manifest.uploadID)
            value.signedManifestObjectSha256.value = manifest.exactManifestObject.objectSHA256.rawBytes
            value.canonicalPcmSha256.value = manifest.canonicalPCMSHA256.rawBytes
            value.totalCanonicalFrames = manifest.totalCanonicalFrames
            value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(manifest.canonicalFormat)
            value.canonicalRecordingRevision = 2
            value.changeCursor = 3
            value.issuedAtUnixMs = durableAt
            value.processingState = .recordingProcessingStatePending
            value.receiptID.value = uuidBytes(ProtocolCodecFixtures.uuid(7_011))
            return value
        }

        static func digest(_ byte: UInt8) -> Data {
            Data(repeating: byte, count: 32)
        }

        private static func uuidBytes(_ value: UUID) -> Data {
            withUnsafeBytes(of: value.uuid) { Data($0) }
        }

        private static func canonicalFormat() -> Harc_V1_CanonicalPCMFormatV1 {
            Harc_V1_CanonicalPCMFormatV1(.harcV1)
        }

        private static func alacEncoding() -> Harc_V1_LosslessEncodingConfigurationV1 {
            Harc_V1_LosslessEncodingConfigurationV1(.cafALAC)
        }
    }
}

private extension Harc_V1_RecordingManifestV1 {
    var uploadIDValue: UUID {
        try! uploadID.domainValue().rawValue
    }
}
