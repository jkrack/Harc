import Foundation
import HarcHost
import HarcProtocol

/// Frozen-v1 capability producer. The host domain sees only semantic
/// projections; protobuf validation, deterministic intersection, and exact
/// once-serialization stay at this composition boundary.
public struct HarcHostInfoProtocolAdapterV1: HostInfoProtocolBoundary {
    private let capabilityPolicy: HarcCapabilityPolicyV1
    private let hostOffer: HarcValidatedCapabilityOfferV1

    public init(
        capabilityPolicy: HarcCapabilityPolicyV1,
        hostOffer: Harc_V1_CapabilityOfferV1
    ) throws {
        let validated = try HarcValidatedCapabilityOfferV1(
            hostOffer,
            policy: capabilityPolicy
        )
        guard Set(validated.requirements.requiredFeatures)
                .isSubset(of: validated.supportedFeatureIDs),
              Set(validated.supportedFeatureIDs)
                .isSubset(of: capabilityPolicy.supportedFeatureIDs),
              Set(validated.supportedDescriptorSchemaIDs)
                .isSubset(of: capabilityPolicy.supportedDescriptorSchemaIDs),
              Set(validated.supportedEncodings)
                .isSubset(of: capabilityPolicy.supportedEncodings),
              Set(validated.supportedCanonicalFormats)
                .isSubset(of: capabilityPolicy.supportedCanonicalFormats) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "hostCapabilityOffer.policy"
            )
        }
        self.capabilityPolicy = capabilityPolicy
        self.hostOffer = validated
    }

    public func validateProtocolVersion(
        major: UInt16,
        minor: UInt16
    ) throws {
        try capabilityPolicy.compatibility.versionPolicy.validate(
            HarcProtocolVersion(major: major, minor: minor)
        )
    }

    public func advertisedCapabilityOffers() throws
        -> [HostInfoCapabilityOffer]
    {
        [try Self.project(hostOffer)]
    }

    public func negotiateCapabilities(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        clientOffer: HostInfoCapabilityOffer
    ) throws -> HostNegotiatedSessionCapabilities {
        try validateProtocolVersion(major: protocolMajor, minor: protocolMinor)
        let client = try HarcValidatedCapabilityOfferV1(
            Self.wireValue(clientOffer),
            policy: capabilityPolicy
        )
        guard client.protocolMajor == protocolMajor,
              (client.minimumProtocolMinor ... client.maximumProtocolMinor)
                .contains(protocolMinor),
              hostOffer.protocolMajor == protocolMajor,
              (hostOffer.minimumProtocolMinor ... hostOffer.maximumProtocolMinor)
                .contains(protocolMinor) else {
            throw HarcProtobufConversionError.inconsistentField(
                "capabilityNegotiation.protocol"
            )
        }

        let selectedFeatures = Set(client.supportedFeatureIDs)
            .intersection(hostOffer.supportedFeatureIDs)
            .sorted()
        let requiredFeatures = Set(client.requirements.requiredFeatures)
            .union(hostOffer.requirements.requiredFeatures)
            .sorted()
        guard Set(requiredFeatures).isSubset(of: selectedFeatures) else {
            throw HarcProtobufConversionError.inconsistentField(
                "capabilityNegotiation.requiredFeatures"
            )
        }
        let commonEncodings = Set(client.supportedEncodings)
            .intersection(hostOffer.supportedEncodings)
        let commonFormats = Set(client.supportedCanonicalFormats)
            .intersection(hostOffer.supportedCanonicalFormats)
        guard let descriptorSchema = Set(client.supportedDescriptorSchemaIDs)
                .intersection(hostOffer.supportedDescriptorSchemaIDs)
                .sorted().first,
              let encoding = client.supportedEncodings.first(
                  where: commonEncodings.contains
              ),
              let canonicalFormat = client.supportedCanonicalFormats.first(
                  where: commonFormats.contains
              ) else {
            throw HarcProtobufConversionError.inconsistentField(
                "capabilityNegotiation.selection"
            )
        }

        let requirements = try HarcValidatedProtocolRequirements(
            requiredFeatures: requiredFeatures,
            criticalFieldNumbers: []
        )
        var wire = Harc_V1_NegotiatedCapabilitiesV1()
        wire.protocol = HarcProtocolVersion(
            major: protocolMajor,
            minor: protocolMinor
        ).protobufV1(requirements: requirements)
        wire.selectedFeatureIds = selectedFeatures
        wire.descriptorSchemaID = descriptorSchema
        wire.encoding = Harc_V1_LosslessEncodingConfigurationV1(encoding)
        wire.canonicalFormat = Harc_V1_CanonicalPCMFormatV1(canonicalFormat)

        let validated = try HarcValidatedNegotiatedCapabilitiesV1(
            serializingOnce: wire,
            policy: capabilityPolicy
        )
        try validated.validateSelection(
            clientOffer: client,
            hostOffer: hostOffer
        )
        return try HostNegotiatedSessionCapabilities(
            exactBytes: validated.exactPayload.exactBytes,
            sha256: validated.exactSHA256,
            protocolMajor: validated.protocolVersion.major,
            protocolMinor: validated.protocolVersion.minor,
            selectedCodec: validated.encoding.codec.rawValue,
            selectedContainer: validated.encoding.container.rawValue
        )
    }

    static func project(
        _ value: HarcValidatedCapabilityOfferV1
    ) throws -> HostInfoCapabilityOffer {
        try HostInfoCapabilityOffer(
            protocolMajor: value.protocolMajor,
            minimumProtocolMinor: value.minimumProtocolMinor,
            maximumProtocolMinor: value.maximumProtocolMinor,
            requiredFeatureIDs: value.requirements.requiredFeatures,
            criticalFieldNumbers: value.requirements.criticalFieldNumbers,
            supportedFeatureIDs: value.supportedFeatureIDs,
            supportedDescriptorSchemaIDs: value.supportedDescriptorSchemaIDs,
            supportedEncodings: value.supportedEncodings,
            supportedCanonicalFormats: value.supportedCanonicalFormats
        )
    }

    static func wireValue(
        _ value: HostInfoCapabilityOffer
    ) throws -> Harc_V1_CapabilityOfferV1 {
        var wire = Harc_V1_CapabilityOfferV1()
        wire.protocolMajor = UInt32(value.protocolMajor)
        wire.minimumProtocolMinor = UInt32(value.minimumProtocolMinor)
        wire.maximumProtocolMinor = UInt32(value.maximumProtocolMinor)
        wire.requirements = try HarcValidatedProtocolRequirements(
            requiredFeatures: value.requiredFeatureIDs,
            criticalFieldNumbers: value.criticalFieldNumbers
        ).protobufV1
        wire.supportedFeatureIds = value.supportedFeatureIDs
        wire.supportedDescriptorSchemaIds = value.supportedDescriptorSchemaIDs
        wire.supportedEncodings = value.supportedEncodings.map(
            Harc_V1_LosslessEncodingConfigurationV1.init
        )
        wire.supportedCanonicalFormats = value.supportedCanonicalFormats.map(
            Harc_V1_CanonicalPCMFormatV1.init
        )
        return wire
    }

}
