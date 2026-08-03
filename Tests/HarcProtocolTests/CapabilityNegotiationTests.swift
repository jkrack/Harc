import CryptoKit
import Foundation
@testable import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Capability offers and exact negotiated payloads")
struct CapabilityNegotiationTests {
    @Test("canonical offers and exact negotiated payloads bind every selection")
    func validatedSelection() throws {
        let policy = try fixturePolicy()
        let client = try HarcValidatedCapabilityOfferV1(
            offer(features: ["capture.gaps.v1", "transfer.chunk.v1"]),
            policy: policy
        )
        let host = try HarcValidatedCapabilityOfferV1(
            offer(features: ["capture.gaps.v1", "transfer.chunk.v1"]),
            policy: policy
        )

        var negotiated = Harc_V1_NegotiatedCapabilitiesV1()
        negotiated.protocol = protocolVersion(requiredFeatures: ["transfer.chunk.v1"])
        negotiated.selectedFeatureIds = ["capture.gaps.v1", "transfer.chunk.v1"]
        negotiated.descriptorSchemaID = "harc.chunk-descriptor.v1"
        negotiated.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        negotiated.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)

        let exact = try HarcExactProtobufPayload(serializingOnce: negotiated)
        let digest = Data(SHA256.hash(data: exact.exactBytes))
        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: exact.exactBytes,
            expectedSHA256: digest,
            policy: policy
        )
        try validated.validateSelection(clientOffer: client, hostOffer: host)

        #expect(validated.exactPayload.exactBytes == exact.exactBytes)
        #expect(validated.exactSHA256 == digest)
        #expect(validated.protocolVersion == .v1)
        #expect(validated.requirements.requiredFeatures == ["transfer.chunk.v1"])
        #expect(validated.selectedFeatureIDs == ["capture.gaps.v1", "transfer.chunk.v1"])
        #expect(validated.encoding == .rawPCMFixture)
        #expect(validated.canonicalFormat == .harcV1)
    }

    @Test("offer ranges, lists, fixture PCM, and selected values fail closed")
    func offerRejections() throws {
        let fixturePolicy = try fixturePolicy()
        var reversedFeatures = offer(features: ["transfer.chunk.v1", "capture.gaps.v1"])
        #expect(throws: HarcProtobufConversionError.nonCanonicalOrder(
            field: "capabilityOffer.supportedFeatureIDs"
        )) {
            try HarcValidatedCapabilityOfferV1(reversedFeatures, policy: fixturePolicy)
        }

        reversedFeatures = offer(features: ["capture.gaps.v1", "capture.gaps.v1"])
        #expect(throws: HarcProtobufConversionError.duplicateValue(
            field: "capabilityOffer.supportedFeatureIDs"
        )) {
            try HarcValidatedCapabilityOfferV1(reversedFeatures, policy: fixturePolicy)
        }

        var badRange = offer(features: [])
        badRange.minimumProtocolMinor = 1
        badRange.maximumProtocolMinor = 0
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "capabilityOffer.protocolRange"
        )) {
            try HarcValidatedCapabilityOfferV1(badRange, policy: fixturePolicy)
        }

        let productionPolicy = try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.cafALAC]
        )
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "capabilityOffer.rawPCMFixture"
        )) {
            try HarcValidatedCapabilityOfferV1(offer(features: []), policy: productionPolicy)
        }

        var unsupported = Harc_V1_NegotiatedCapabilitiesV1()
        unsupported.protocol = protocolVersion()
        unsupported.selectedFeatureIds = ["future.feature"]
        unsupported.descriptorSchemaID = "harc.chunk-descriptor.v1"
        unsupported.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        unsupported.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        #expect(throws: HarcProtobufConversionError.unsupportedRequiredFeature("future.feature")) {
            try HarcValidatedNegotiatedCapabilitiesV1(
                serializingOnce: unsupported,
                policy: fixturePolicy
            )
        }
    }

    @Test("negotiated bytes preserve additive fields and reject hash or offer mismatch")
    func exactBytesAndBindingFailures() throws {
        let policy = try fixturePolicy()
        var negotiated = Harc_V1_NegotiatedCapabilitiesV1()
        negotiated.protocol = protocolVersion()
        negotiated.selectedFeatureIds = ["transfer.chunk.v1"]
        negotiated.descriptorSchemaID = "harc.chunk-descriptor.v1"
        negotiated.encoding = Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture)
        negotiated.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(.harcV1)
        var exactBytes = try negotiated.serializedData()
        exactBytes.append(contentsOf: [0xa2, 0x06, 0x01, 0xff])
        let digest = Data(SHA256.hash(data: exactBytes))

        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: exactBytes,
            expectedSHA256: digest,
            policy: policy
        )
        #expect(validated.exactPayload.exactBytes == exactBytes)

        var wrongDigest = digest
        wrongDigest[0] ^= 1
        #expect(throws: HarcProtobufConversionError.exactPayloadHashMismatch) {
            try HarcValidatedNegotiatedCapabilitiesV1(
                decoding: exactBytes,
                expectedSHA256: wrongDigest,
                policy: policy
            )
        }

        let client = try HarcValidatedCapabilityOfferV1(
            offer(features: ["transfer.chunk.v1"]),
            policy: policy
        )
        let host = try HarcValidatedCapabilityOfferV1(
            offer(features: []),
            policy: policy
        )
        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "negotiatedCapabilities.selectedFeatureIDs"
        )) {
            try validated.validateSelection(clientOffer: client, hostOffer: host)
        }
    }

    private func fixturePolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: ["transfer.chunk.v1"]
            ),
            supportedFeatureIDs: ["capture.gaps.v1", "transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func offer(features: [String]) -> Harc_V1_CapabilityOfferV1 {
        var value = Harc_V1_CapabilityOfferV1()
        value.protocolMajor = 1
        value.minimumProtocolMinor = 0
        value.maximumProtocolMinor = 0
        value.supportedFeatureIds = features
        value.supportedDescriptorSchemaIds = ["harc.chunk-descriptor.v1"]
        value.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.rawPCMFixture),
        ]
        value.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return value
    }

    private func protocolVersion(
        requiredFeatures: [String] = []
    ) -> Harc_V1_ProtocolVersionV1 {
        var value = Harc_V1_ProtocolVersionV1()
        value.major = 1
        value.minor = 0
        value.requirements.requiredFeatures = requiredFeatures
        return value
    }
}
