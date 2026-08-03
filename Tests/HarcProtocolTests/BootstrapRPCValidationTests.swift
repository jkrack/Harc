import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Pairing and session bootstrap RPC validation")
struct BootstrapRPCValidationTests {
    @Test("public host bootstrap validates protocol and exact client offer semantics")
    func hostInfoAndNegotiationValidation() throws {
        var hostInfo = Harc_V1_GetHostInfoRequestV1()
        hostInfo.protocol = HarcProtocolVersion.v1.protobufV1()
        #expect(
            try HarcValidatedGetHostInfoRequestV1(hostInfo).protocolVersion == .v1
        )

        let policy = try fixtureCapabilityPolicy()
        var request = Harc_V1_NegotiateCapabilitiesRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.clientOffer = fixtureCapabilityOffer()
        let validated = try HarcValidatedNegotiateCapabilitiesRequestV1(
            request,
            policy: policy
        )
        #expect(validated.protocolVersion == .v1)
        #expect(validated.clientOffer.supportedFeatureIDs == ["transfer.chunk.v1"])

        var missingOffer = request
        missingOffer.clearClientOffer()
        #expect(throws: HarcProtobufConversionError.missingField(
            "negotiateCapabilities.clientOffer"
        )) {
            try HarcValidatedNegotiateCapabilitiesRequestV1(
                missingOffer,
                policy: policy
            )
        }

        var incompatibleRange = request
        incompatibleRange.clientOffer.minimumProtocolMinor = 1
        incompatibleRange.clientOffer.maximumProtocolMinor = 1
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "negotiateCapabilities.protocol"
        )) {
            try HarcValidatedNegotiateCapabilitiesRequestV1(
                incompatibleRange,
                policy: policy
            )
        }
    }

    @Test("begin pairing validates the secret, nonce, key, canonical scopes, and label")
    func beginPairingValidation() throws {
        let key = SoftwareP256SigningKey()
        let ticketID = UUID()
        let request = beginPairingRequest(key: key, ticketID: ticketID)
        let validated = try HarcValidatedBeginPairingClaimRequestV1(request)

        #expect(validated.ticketID == ticketID)
        #expect(validated.devicePublicKey == key.publicKey)
        #expect(validated.devicePublicKey.deviceID == key.publicKey.deviceID)
        #expect(validated.requestedScopes == [.libraryMetadataRead, .recordingUploadOwn])
        #expect(validated.deviceLabel == "Jordan’s iPhone")

        var shortSecret = request
        shortSecret.ticketSecret = Data(repeating: 1, count: 23)
        #expect(throws: HarcProtobufConversionError.invalidLength(
            field: "beginPairingClaim.ticketSecret",
            expected: 24,
            actual: 23
        )) {
            try HarcValidatedBeginPairingClaimRequestV1(shortSecret)
        }

        var reversedScopes = request
        reversedScopes.requestedScopes.reverse()
        #expect(throws: HarcProtobufConversionError.nonCanonicalOrder(
            field: "beginPairingClaim.requestedScopes"
        )) {
            try HarcValidatedBeginPairingClaimRequestV1(reversedScopes)
        }

        var duplicateScopes = request
        duplicateScopes.requestedScopes = [
            .authorizationScopeRecordingUploadOwn,
            .authorizationScopeRecordingUploadOwn,
        ]
        #expect(throws: HarcProtobufConversionError.duplicateValue(
            field: "beginPairingClaim.requestedScopes"
        )) {
            try HarcValidatedBeginPairingClaimRequestV1(duplicateScopes)
        }

        var decomposedLabel = request
        decomposedLabel.deviceLabel = "Cafe\u{301}"
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "beginPairingClaim.deviceLabel"
        )) {
            try HarcValidatedBeginPairingClaimRequestV1(decomposedLabel)
        }

        var emptyLabel = request
        emptyLabel.deviceLabel = ""
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "beginPairingClaim.deviceLabel"
        )) {
            try HarcValidatedBeginPairingClaimRequestV1(emptyLabel)
        }
    }

    @Test("pairing proof and status require canonical UUIDs and low-S signatures")
    func pairingProofAndStatusValidation() throws {
        let claimID = UUID()
        let key = SoftwareP256SigningKey()
        let signature = try key.sign(
            digest: P256SHA256Digest(Data(repeating: 0x42, count: 32))
        )

        var proof = Harc_V1_ProvePairingClaimRequestV1()
        proof.protocol = HarcProtocolVersion.v1.protobufV1()
        proof.claimID = Harc_V1_ClaimIDV1(claimID)
        proof.clientSignatureRaw = signature.rawBytes
        let validatedProof = try HarcValidatedProvePairingClaimRequestV1(proof)
        #expect(validatedProof.claimID == claimID)
        #expect(validatedProof.clientSignature == signature)

        var status = Harc_V1_GetPairingStatusRequestV1()
        status.protocol = HarcProtocolVersion.v1.protobufV1()
        status.claimID = Harc_V1_ClaimIDV1(claimID)
        #expect(try HarcValidatedGetPairingStatusRequestV1(status).claimID == claimID)

        proof.clientSignatureRaw = Data(repeating: 0, count: 64)
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "provePairingClaim.clientSignatureRaw"
        )) {
            try HarcValidatedProvePairingClaimRequestV1(proof)
        }

        status.claimID.value = Data(repeating: 0, count: 15)
        #expect(throws: HarcProtobufConversionError.invalidLength(
            field: "claimID",
            expected: 16,
            actual: 15
        )) {
            try HarcValidatedGetPairingStatusRequestV1(status)
        }
    }

    @Test("session bootstrap binds IDs, exact capability bytes, hash, and proof signature")
    func sessionValidation() throws {
        let key = SoftwareP256SigningKey()
        let grantID = GrantID.random()
        var begin = Harc_V1_BeginSessionRequestV1()
        begin.protocol = HarcProtocolVersion.v1.protobufV1()
        begin.claimedDeviceID = Harc_V1_DeviceIDV1(key.publicKey.deviceID)
        begin.grantID = Harc_V1_GrantIDV1(grantID)
        let validatedBegin = try HarcValidatedBeginSessionRequestV1(begin)
        #expect(validatedBegin.claimedDeviceID == key.publicKey.deviceID)
        #expect(validatedBegin.grantID == grantID)

        let policy = try fixtureCapabilityPolicy()
        let exactCapabilities = try exactFixtureCapabilities()
        let digest = Data(SHA256.hash(data: exactCapabilities))
        let challengeID = UUID()
        let signature = try key.sign(
            digest: P256SHA256Digest(Data(repeating: 0x53, count: 32))
        )
        var open = Harc_V1_OpenSessionRequestV1()
        open.protocol = HarcProtocolVersion.v1.protobufV1()
        open.challengeID = Harc_V1_ChallengeIDV1(challengeID)
        open.clientNonce = Data(repeating: 0x51, count: 32)
        open.exactNegotiatedCapabilitiesPayload = exactCapabilities
        open.negotiatedCapabilitiesSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: digest
        )
        open.clientSignatureRaw = signature.rawBytes

        let validatedOpen = try HarcValidatedOpenSessionRequestV1(
            open,
            capabilityPolicy: policy
        )
        #expect(validatedOpen.challengeID == challengeID)
        #expect(validatedOpen.negotiatedCapabilities.exactPayload.exactBytes
            == exactCapabilities)
        #expect(validatedOpen.negotiatedCapabilities.exactSHA256 == digest)
        #expect(validatedOpen.clientSignature == signature)

        var wrongHash = open
        wrongHash.negotiatedCapabilitiesSha256.value[0] ^= 1
        #expect(throws: HarcProtobufConversionError.exactPayloadHashMismatch) {
            try HarcValidatedOpenSessionRequestV1(
                wrongHash,
                capabilityPolicy: policy
            )
        }

        var shortNonce = open
        shortNonce.clientNonce.removeLast()
        #expect(throws: HarcProtobufConversionError.invalidLength(
            field: "openSession.clientNonce",
            expected: 32,
            actual: 31
        )) {
            try HarcValidatedOpenSessionRequestV1(
                shortNonce,
                capabilityPolicy: policy
            )
        }
    }

    private func beginPairingRequest(
        key: SoftwareP256SigningKey,
        ticketID: UUID
    ) -> Harc_V1_BeginPairingClaimRequestV1 {
        var value = Harc_V1_BeginPairingClaimRequestV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.ticketID = Harc_V1_TicketIDV1(ticketID)
        value.ticketSecret = Data(repeating: 0x21, count: 24)
        value.clientNonce = Data(repeating: 0x22, count: 32)
        value.devicePublicKeyX963 = key.publicKey.rawBytes
        value.requestedScopes = [
            .authorizationScopeLibraryMetadataRead,
            .authorizationScopeRecordingUploadOwn,
        ]
        value.deviceLabel = "Jordan’s iPhone"
        return value
    }

    private func fixtureCapabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: ["transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func exactFixtureCapabilities() throws -> Data {
        var value = Harc_V1_NegotiatedCapabilitiesV1()
        value.protocol = HarcProtocolVersion.v1.protobufV1()
        value.selectedFeatureIds = ["transfer.chunk.v1"]
        value.descriptorSchemaID = "harc.chunk-descriptor.v1"
        value.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        value.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        return try value.serializedData()
    }

    private func fixtureCapabilityOffer() -> Harc_V1_CapabilityOfferV1 {
        var value = Harc_V1_CapabilityOfferV1()
        value.protocolMajor = 1
        value.minimumProtocolMinor = 0
        value.maximumProtocolMinor = 0
        value.supportedFeatureIds = ["transfer.chunk.v1"]
        value.supportedDescriptorSchemaIds = ["harc.chunk-descriptor.v1"]
        value.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture),
        ]
        value.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return value
    }
}
