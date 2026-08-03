import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcTransfer
import Testing

@Suite("Canonical signed envelope and registry")
struct SignedEnvelopeCodecTests {
    @Test("all nine registered rows sign, decode, preserve, mirror, and verify")
    func allRegisteredRows() throws {
        let hostKey = ProtocolCodecFixtures.key(1)
        let deviceKey = ProtocolCodecFixtures.key(2)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(10))
        let grantID = ProtocolCodecFixtures.uuid(20)
        let operationID = ProtocolCodecFixtures.uuid(30)
        let issuedAt = ProtocolCodecFixtures.issuedAt

        let rows: [(HarcSignedMessageTypeV1, HarcSignedPayloadTypeV1, Bool, Bool, Bool, Bool, Bool)] = [
            (.hostTransportSet, .hostTransportSet, false, false, false, false, false),
            (.deviceGrant, .deviceGrant, false, true, false, true, false),
            (.deviceRevocation, .deviceRevocation, false, true, true, false, false),
            (.recordingManifest, .recordingManifest, true, false, true, false, false),
            (.batchAcknowledgement, .batchAcknowledgement, false, false, true, false, false),
            (.recordingReceipt, .recordingReceipt, false, false, true, false, false),
            (.metadataMutation, .metadataMutation, true, true, true, true, true),
            (.processingArtifact, .processingArtifact, true, true, true, true, false),
            (.portableTrustHistory, .portableTrustHistory, false, false, true, false, false),
        ]

        for (index, row) in rows.enumerated() {
            let payload = Data([0x08, UInt8(index), 0xa2, 0x06, 0x01, 0xff])
            let usesDevice = row.2
            let hasGrant = row.3
            let hasOperation = row.4
            let hasExpiry = row.5
            let hasRevision = row.6
            let expiry = hasExpiry ? issuedAt + 60_000 : nil
            let header = try HarcSignedEnvelopeV1(
                messageType: row.0,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                signerDeviceID: usesDevice ? deviceKey.publicKey.deviceID : nil,
                grantID: hasGrant ? grantID : nil,
                grantEpoch: hasGrant ? 3 : 0,
                operationID: hasOperation ? operationID : nil,
                issuedAtUnixMilliseconds: issuedAt,
                expiresAtUnixMilliseconds: expiry,
                payloadType: row.1,
                expectedRevision: hasRevision ? 0 : nil,
                payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
            )
            let signer = usesDevice ? deviceKey : hostKey
            let bindings = HarcSignedPayloadBindingsV1(
                protocolVersion: .v1,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                issuedAtUnixMilliseconds: issuedAt,
                signerDeviceID: usesDevice ? deviceKey.publicKey.deviceID : nil,
                grantID: hasGrant ? grantID : nil,
                grantEpoch: hasGrant ? 3 : nil,
                operationID: hasOperation ? operationID : nil,
                expiresAtUnixMilliseconds: expiry,
                expectedRevision: hasRevision ? 0 : nil
            )
            let signed = try HarcSignedObjectV1.signRegistered(
                header: header,
                exactPayloadBytes: payload,
                payloadBindings: bindings,
                using: signer
            )
            let decoded = try HarcSignedObjectV1.decode(signed.exactFramedBytes)

            #expect(decoded.exactFramedBytes == signed.exactFramedBytes)
            #expect(decoded.exactHeaderBytes == signed.exactHeaderBytes)
            #expect(decoded.exactPayloadBytes == payload)
            #expect(decoded.objectID.rawBytes == Data(SHA256.hash(
                data: Data("HARC-SIGNED-OBJECT-ID-V1\0".utf8) + signed.exactFramedBytes
            )))
            let isCommand = row.0 == .metadataMutation || row.0 == .processingArtifact
            let currentGrant = isCommand
                ? try ProtocolCodecFixtures.currentGrantBinding(
                    libraryID: libraryID,
                    hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                    deviceKey: deviceKey,
                    grantID: grantID,
                    grantEpoch: 3
                )
                : nil
            try decoded.verifyRegistered(
                using: signer.publicKey,
                payloadBindings: bindings,
                acceptedAtUnixMilliseconds: isCommand ? issuedAt + 1 : nil,
                currentGrant: currentGrant
            )
        }
    }

    @Test("registry admission is mandatory before signing and decoding")
    func registryAdmissionCannotBeBypassed() throws {
        let hostKey = ProtocolCodecFixtures.key(3)
        let deviceKey = ProtocolCodecFixtures.key(4)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(40))
        let digest = HarcSignedEnvelopeV1.payloadDigest(Data())

        #expect(throws: HarcProtocolCodecError.unregisteredSignedObject(
            messageType: HarcSignedMessageTypeV1.hostTransportSet.rawValue,
            payloadType: HarcSignedPayloadTypeV1.deviceGrant.rawValue
        )) {
            try HarcSignedEnvelopeV1(
                messageType: .hostTransportSet,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                signerDeviceID: nil,
                grantID: nil,
                grantEpoch: 0,
                operationID: nil,
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: nil,
                payloadType: .deviceGrant,
                expectedRevision: nil,
                payloadSHA256: digest
            )
        }

        #expect(throws: HarcProtocolCodecError.wrongSignerClass) {
            try HarcSignedEnvelopeV1(
                messageType: .recordingManifest,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                signerDeviceID: nil,
                grantID: nil,
                grantEpoch: 0,
                operationID: ProtocolCodecFixtures.uuid(41),
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: nil,
                payloadType: .recordingManifest,
                expectedRevision: nil,
                payloadSHA256: digest
            )
        }

        let validHeader = try HarcSignedEnvelopeV1(
            messageType: .hostTransportSet,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: nil,
            issuedAtUnixMilliseconds: 1,
            expiresAtUnixMilliseconds: nil,
            payloadType: .hostTransportSet,
            expectedRevision: nil,
            payloadSHA256: digest
        )
        #expect(throws: HarcProtocolCodecError.invalidKeyBinding(field: "hostAuthorityID")) {
            try HarcSignedObjectV1.sign(
                header: validHeader,
                exactPayloadBytes: Data(),
                using: deviceKey
            )
        }
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(field: "libraryID")) {
            try HarcSignedObjectV1.signRegistered(
                header: validHeader,
                exactPayloadBytes: Data(),
                payloadBindings: HarcSignedPayloadBindingsV1(
                    protocolVersion: .v1,
                    libraryID: LibraryID(ProtocolCodecFixtures.uuid(999)),
                    hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                    issuedAtUnixMilliseconds: 1
                ),
                using: hostKey
            )
        }

        let validObject = try HarcSignedObjectV1.sign(
            header: validHeader,
            exactPayloadBytes: Data(),
            using: hostKey
        )
        var structuralTamper = validObject.exactFramedBytes
        let signerOffsetInHeader = 8 + 2 + validHeader.messageType.rawValue.utf8.count
            + 2 + 2 + 16 + 32
        let signerOffsetInFrame = 8 + 4 + signerOffsetInHeader
        structuralTamper[signerOffsetInFrame] = 1
        #expect(throws: HarcProtocolCodecError.wrongSignerClass) {
            try HarcSignedObjectV1.decode(structuralTamper)
        }
    }

    @Test("nil is the only canonical all-zero optional UUID representation")
    func zeroUUIDCannotBePresentedAsNonnil() throws {
        let hostKey = ProtocolCodecFixtures.key(5)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(50))
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(field: "grantID")) {
            try HarcSignedEnvelopeV1(
                messageType: .deviceGrant,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                signerDeviceID: nil,
                grantID: HarcSignedEnvelopeV1.zeroUUID,
                grantEpoch: 1,
                operationID: nil,
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: nil,
                payloadType: .deviceGrant,
                expectedRevision: nil,
                payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(Data())
            )
        }
        #expect(throws: HarcProtocolCodecError.headerPayloadMismatch(field: "operationID")) {
            try HarcSignedEnvelopeV1(
                messageType: .recordingReceipt,
                libraryID: libraryID,
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                signerDeviceID: nil,
                grantID: nil,
                grantEpoch: 0,
                operationID: HarcSignedEnvelopeV1.zeroUUID,
                issuedAtUnixMilliseconds: 1,
                expiresAtUnixMilliseconds: nil,
                payloadType: .recordingReceipt,
                expectedRevision: nil,
                payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(Data())
            )
        }
    }

    @Test("exact payload tamper and high-S frame fail closed")
    func tamperAndHighS() throws {
        let hostKey = ProtocolCodecFixtures.key(6)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(60))
        let payload = Data([0x08, 0x80, 0x00, 0x98, 0x06, 0x01])
        let header = try HarcSignedEnvelopeV1(
            messageType: .hostTransportSet,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: nil,
            grantID: nil,
            grantEpoch: 0,
            operationID: nil,
            issuedAtUnixMilliseconds: 1,
            expiresAtUnixMilliseconds: nil,
            payloadType: .hostTransportSet,
            expectedRevision: nil,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        let object = try HarcSignedObjectV1.sign(
            header: header,
            exactPayloadBytes: payload,
            using: hostKey
        )

        var payloadTamper = object.exactFramedBytes
        let payloadOffset = 8 + 4 + object.exactHeaderBytes.count + 8
        payloadTamper[payloadOffset] ^= 1
        #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            try HarcSignedObjectV1.decode(payloadTamper)
        }

        var highSFrame = object.exactFramedBytes
        let highSignature = try Data(protocolHex: """
            EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
            F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8
            """)
        highSFrame.replaceSubrange((highSFrame.count - 64) ..< highSFrame.count, with: highSignature)
        #expect(throws: IdentityCryptoError.signatureNotLowS) {
            try HarcSignedObjectV1.decode(highSFrame)
        }
    }

    @Test("command bounds and current grant are enforced only at initial acceptance")
    func commandAcceptance() throws {
        let hostKey = ProtocolCodecFixtures.key(7)
        let deviceKey = ProtocolCodecFixtures.key(8)
        let libraryID = LibraryID(ProtocolCodecFixtures.uuid(70))
        let grantID = ProtocolCodecFixtures.uuid(71)
        let operationID = ProtocolCodecFixtures.uuid(72)
        let issuedAt: UInt64 = 1_000_000
        let expiry = issuedAt + 10_000
        let payload = Data([1])
        let header = try HarcSignedEnvelopeV1(
            messageType: .metadataMutation,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            signerDeviceID: deviceKey.publicKey.deviceID,
            grantID: grantID,
            grantEpoch: 4,
            operationID: operationID,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiry,
            payloadType: .metadataMutation,
            expectedRevision: 0,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(payload)
        )
        let bindings = HarcSignedPayloadBindingsV1(
            protocolVersion: .v1,
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            issuedAtUnixMilliseconds: issuedAt,
            signerDeviceID: deviceKey.publicKey.deviceID,
            grantID: grantID,
            grantEpoch: 4,
            operationID: operationID,
            expiresAtUnixMilliseconds: expiry,
            expectedRevision: 0
        )
        let object = try HarcSignedObjectV1.signRegistered(
            header: header,
            exactPayloadBytes: payload,
            payloadBindings: bindings,
            using: deviceKey
        )

        try object.verifyRegistered(using: deviceKey.publicKey, payloadBindings: bindings)
        let current = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 4
        )
        #expect(throws: HarcProtocolCodecError.commandExpired) {
            try object.verifyRegistered(
                using: deviceKey.publicKey,
                payloadBindings: bindings,
                acceptedAtUnixMilliseconds: expiry,
                currentGrant: current
            )
        }
        let stale = try ProtocolCodecFixtures.currentGrantBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            deviceKey: deviceKey,
            grantID: grantID,
            grantEpoch: 5
        )
        #expect(throws: HarcProtocolCodecError.staleGrant) {
            try object.verifyRegistered(
                using: deviceKey.publicKey,
                payloadBindings: bindings,
                acceptedAtUnixMilliseconds: issuedAt + 1,
                currentGrant: stale
            )
        }
    }
}
