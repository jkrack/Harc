import Foundation
@testable import HarcHost
@testable import HarcHostTransport
import HarcProtocol
import HarcTransfer
import Testing

@Suite("HostInfo frozen-v1 protocol adapter")
struct HostInfoProtocolAdapterTests {
    @Test("advertisement and negotiation use one canonical deterministic intersection")
    func deterministicNegotiation() throws {
        let policy = try capabilityPolicy()
        let adapter = try HarcHostInfoProtocolAdapterV1(
            capabilityPolicy: policy,
            hostOffer: offer(
                required: ["transfer.chunk.v1"],
                features: ["capture.gaps.v1", "transfer.chunk.v1"]
            )
        )
        let _: any HostInfoProtocolBoundary = adapter
        let projected = try #require(
            adapter.advertisedCapabilityOffers().first
        )

        let negotiated = try adapter.negotiateCapabilities(
            protocolMajor: 1,
            protocolMinor: 0,
            clientOffer: try HostInfoCapabilityOffer(
                protocolMajor: 1,
                minimumProtocolMinor: 0,
                maximumProtocolMinor: 0,
                requiredFeatureIDs: ["transfer.chunk.v1"],
                supportedFeatureIDs: [
                    "capture.gaps.v1",
                    "transfer.chunk.v1",
                ],
                supportedDescriptorSchemaIDs: [
                    "harc.chunk-descriptor.v1",
                ],
                supportedEncodings: [.rawPCMFixture],
                supportedCanonicalFormats: [.harcV1]
            )
        )
        let decoded = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: negotiated.exactBytes,
            expectedSHA256: negotiated.sha256,
            policy: policy
        )

        #expect(projected.requiredFeatureIDs == ["transfer.chunk.v1"])
        #expect(decoded.protocolVersion == .v1)
        #expect(decoded.requirements.requiredFeatures == ["transfer.chunk.v1"])
        #expect(decoded.selectedFeatureIDs == [
            "capture.gaps.v1",
            "transfer.chunk.v1",
        ])
        #expect(decoded.descriptorSchemaID == "harc.chunk-descriptor.v1")
        #expect(decoded.encoding == .rawPCMFixture)
        #expect(decoded.canonicalFormat == .harcV1)
    }

    @Test("a required capability absent from the host intersection fails closed")
    func missingRequiredCapability() throws {
        let adapter = try HarcHostInfoProtocolAdapterV1(
            capabilityPolicy: capabilityPolicy(),
            hostOffer: offer(
                required: ["transfer.chunk.v1"],
                features: ["transfer.chunk.v1"]
            )
        )
        let client = try HostInfoCapabilityOffer(
            protocolMajor: 1,
            minimumProtocolMinor: 0,
            maximumProtocolMinor: 0,
            requiredFeatureIDs: ["capture.gaps.v1"],
            supportedFeatureIDs: [
                "capture.gaps.v1",
                "transfer.chunk.v1",
            ],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            supportedCanonicalFormats: [.harcV1]
        )

        #expect(throws: HarcProtobufConversionError.inconsistentField(
            "capabilityNegotiation.requiredFeatures"
        )) {
            try adapter.negotiateCapabilities(
                protocolMajor: 1,
                protocolMinor: 0,
                clientOffer: client
            )
        }
    }

    @Test("host advertisement cannot exceed the composing capability policy")
    func hostOfferPolicyBoundary() throws {
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "hostCapabilityOffer.policy"
        )) {
            try HarcHostInfoProtocolAdapterV1(
                capabilityPolicy: capabilityPolicy(),
                hostOffer: offer(
                    required: [],
                    features: ["future.feature.v1"]
                )
            )
        }
    }

    @Test("host requirements must be included in the host supported feature set")
    func hostRequiredFeatureSubset() throws {
        #expect(throws: HarcProtobufConversionError.invalidValue(
            field: "hostCapabilityOffer.policy"
        )) {
            try HarcHostInfoProtocolAdapterV1(
                capabilityPolicy: capabilityPolicy(),
                hostOffer: offer(
                    required: ["capture.gaps.v1"],
                    features: ["transfer.chunk.v1"]
                )
            )
        }
    }

    private func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: [
                    "capture.gaps.v1",
                    "transfer.chunk.v1",
                ]
            ),
            supportedFeatureIDs: [
                "capture.gaps.v1",
                "transfer.chunk.v1",
            ],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
    }

    private func offer(
        required: [String],
        features: [String]
    ) -> Harc_V1_CapabilityOfferV1 {
        var value = Harc_V1_CapabilityOfferV1()
        value.protocolMajor = 1
        value.minimumProtocolMinor = 0
        value.maximumProtocolMinor = 0
        value.requirements.requiredFeatures = required
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
}
