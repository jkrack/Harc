import CryptoKit
import Foundation
import HarcDomain
import HarcProtocolWire
import HarcTransfer

/// Local capability policy. The codec set is always supplied by the composing
/// app so PR 4 does not accidentally freeze a production codec before the
/// physical-device qualification gate closes.
public struct HarcCapabilityPolicyV1: Sendable {
    public let compatibility: HarcProtobufCompatibilityPolicy
    public let supportedFeatureIDs: Set<String>
    public let supportedDescriptorSchemaIDs: Set<String>
    public let supportedEncodings: Set<LosslessEncodingConfiguration>
    public let supportedCanonicalFormats: Set<CanonicalPCMFormat>
    public let allowRawPCMFixture: Bool

    public init(
        compatibility: HarcProtobufCompatibilityPolicy = .currentV1,
        supportedFeatureIDs: Set<String>,
        supportedDescriptorSchemaIDs: Set<String>,
        supportedEncodings: Set<LosslessEncodingConfiguration>,
        supportedCanonicalFormats: Set<CanonicalPCMFormat> = [.harcV1],
        allowRawPCMFixture: Bool = false
    ) throws {
        try harcValidateCapabilityCodes(
            supportedFeatureIDs.sorted(),
            field: "capabilityPolicy.supportedFeatureIDs"
        )
        try harcValidateCapabilityCodes(
            supportedDescriptorSchemaIDs.sorted(),
            field: "capabilityPolicy.supportedDescriptorSchemaIDs"
        )
        guard !supportedDescriptorSchemaIDs.isEmpty,
              !supportedEncodings.isEmpty,
              !supportedCanonicalFormats.isEmpty else {
            throw HarcProtobufConversionError.invalidValue(
                field: "capabilityPolicy.emptySelectionSet"
            )
        }
        if !allowRawPCMFixture,
           supportedEncodings.contains(where: { $0 == .rawPCMFixture }) {
            throw HarcProtobufConversionError.invalidValue(
                field: "capabilityPolicy.rawPCMFixture"
            )
        }
        self.compatibility = compatibility
        self.supportedFeatureIDs = supportedFeatureIDs
        self.supportedDescriptorSchemaIDs = supportedDescriptorSchemaIDs
        self.supportedEncodings = supportedEncodings
        self.supportedCanonicalFormats = supportedCanonicalFormats
        self.allowRawPCMFixture = allowRawPCMFixture
    }
}

/// Canonically validated semantic view of one capability offer.
public struct HarcValidatedCapabilityOfferV1: Sendable {
    public let wireValue: Harc_V1_CapabilityOfferV1
    public let protocolMajor: UInt16
    public let minimumProtocolMinor: UInt16
    public let maximumProtocolMinor: UInt16
    public let requirements: HarcValidatedProtocolRequirements
    public let supportedFeatureIDs: [String]
    public let supportedDescriptorSchemaIDs: [String]
    public let supportedEncodings: [LosslessEncodingConfiguration]
    public let supportedCanonicalFormats: [CanonicalPCMFormat]

    public init(
        _ value: Harc_V1_CapabilityOfferV1,
        policy: HarcCapabilityPolicyV1
    ) throws {
        guard let major = UInt16(exactly: value.protocolMajor),
              let minimumMinor = UInt16(exactly: value.minimumProtocolMinor),
              let maximumMinor = UInt16(exactly: value.maximumProtocolMinor) else {
            throw HarcProtobufConversionError.integerOutOfRange(
                field: "capabilityOffer.protocolRange"
            )
        }
        guard major == policy.compatibility.versionPolicy.major else {
            throw HarcProtocolCodecError.unsupportedProtocolMajor(major)
        }
        guard minimumMinor <= maximumMinor else {
            throw HarcProtobufConversionError.invalidValue(
                field: "capabilityOffer.protocolRange"
            )
        }

        let requirements = try HarcValidatedProtocolRequirements(
            requiredFeatures: value.hasRequirements
                ? value.requirements.requiredFeatures
                : [],
            criticalFieldNumbers: value.hasRequirements
                ? value.requirements.criticalFieldNumbers
                : []
        )
        for feature in requirements.requiredFeatures
            where !policy.compatibility.supportedRequiredFeatures.contains(feature) {
            throw HarcProtobufConversionError.unsupportedRequiredFeature(feature)
        }
        for number in requirements.criticalFieldNumbers
            where !(1 ... 8).contains(number) {
            throw HarcProtobufConversionError.unknownCriticalField(number)
        }

        try harcValidateCapabilityCodes(
            value.supportedFeatureIds,
            field: "capabilityOffer.supportedFeatureIDs"
        )
        try harcValidateCapabilityCodes(
            value.supportedDescriptorSchemaIds,
            field: "capabilityOffer.supportedDescriptorSchemaIDs"
        )
        guard !value.supportedDescriptorSchemaIds.isEmpty,
              !value.supportedEncodings.isEmpty,
              !value.supportedCanonicalFormats.isEmpty else {
            throw HarcProtobufConversionError.missingField(
                "capabilityOffer.selectionSets"
            )
        }

        let encodings = try value.supportedEncodings.map { try $0.domainValue() }
        try harcRequireCanonicalCapabilityEncodings(encodings)
        if !policy.allowRawPCMFixture,
           encodings.contains(where: { $0 == .rawPCMFixture }) {
            throw HarcProtobufConversionError.invalidValue(
                field: "capabilityOffer.rawPCMFixture"
            )
        }

        let formats = try value.supportedCanonicalFormats.map { try $0.domainValue() }
        try harcRequireCanonicalCapabilityFormats(formats)

        self.wireValue = value
        self.protocolMajor = major
        self.minimumProtocolMinor = minimumMinor
        self.maximumProtocolMinor = maximumMinor
        self.requirements = requirements
        self.supportedFeatureIDs = value.supportedFeatureIds
        self.supportedDescriptorSchemaIDs = value.supportedDescriptorSchemaIds
        self.supportedEncodings = encodings
        self.supportedCanonicalFormats = formats
    }
}

/// Exact negotiated capability bytes and their validated semantic projection.
/// The exact SHA-256 is what binds session transcripts and upload profiles.
public struct HarcValidatedNegotiatedCapabilitiesV1: Sendable {
    public let exactPayload: HarcExactProtobufPayload<Harc_V1_NegotiatedCapabilitiesV1>
    public let exactSHA256: Data
    public let protocolVersion: HarcProtocolVersion
    public let requirements: HarcValidatedProtocolRequirements
    public let selectedFeatureIDs: [String]
    public let descriptorSchemaID: String
    public let encoding: LosslessEncodingConfiguration
    public let canonicalFormat: CanonicalPCMFormat

    public init(
        decoding exactBytes: Data,
        expectedSHA256: Data? = nil,
        policy: HarcCapabilityPolicyV1
    ) throws {
        let exact = try HarcExactProtobufPayload(
            decoding: exactBytes,
            as: Harc_V1_NegotiatedCapabilitiesV1.self
        )
        try self.init(
            exactPayload: exact,
            expectedSHA256: expectedSHA256,
            policy: policy
        )
    }

    public init(
        serializingOnce value: Harc_V1_NegotiatedCapabilitiesV1,
        policy: HarcCapabilityPolicyV1
    ) throws {
        let exact = try HarcExactProtobufPayload(serializingOnce: value)
        try self.init(exactPayload: exact, expectedSHA256: nil, policy: policy)
    }

    private init(
        exactPayload: HarcExactProtobufPayload<Harc_V1_NegotiatedCapabilitiesV1>,
        expectedSHA256: Data?,
        policy: HarcCapabilityPolicyV1
    ) throws {
        let digest = Data(SHA256.hash(data: exactPayload.exactBytes))
        if let expectedSHA256 {
            guard expectedSHA256.count == SHA256.Digest.byteCount else {
                throw HarcProtobufConversionError.invalidLength(
                    field: "negotiatedCapabilitiesSHA256",
                    expected: SHA256.Digest.byteCount,
                    actual: expectedSHA256.count
                )
            }
            guard expectedSHA256 == digest else {
                throw HarcProtobufConversionError.exactPayloadHashMismatch
            }
        }

        let value = exactPayload.message
        guard value.hasProtocol else {
            throw HarcProtobufConversionError.missingField(
                "negotiatedCapabilities.protocol"
            )
        }
        let (version, requirements) = try policy.compatibility.validate(
            value.protocol,
            knownCriticalFieldNumbers: Set(1 ... 5)
        )
        try harcValidateCapabilityCodes(
            value.selectedFeatureIds,
            field: "negotiatedCapabilities.selectedFeatureIDs"
        )
        for feature in value.selectedFeatureIds
            where !policy.supportedFeatureIDs.contains(feature) {
            throw HarcProtobufConversionError.unsupportedRequiredFeature(feature)
        }
        for feature in requirements.requiredFeatures
            where !value.selectedFeatureIds.contains(feature) {
            throw HarcProtobufConversionError.inconsistentField(
                "negotiatedCapabilities.requiredFeatures"
            )
        }
        try harcValidateCapabilityCode(
            value.descriptorSchemaID,
            field: "negotiatedCapabilities.descriptorSchemaID"
        )
        guard policy.supportedDescriptorSchemaIDs.contains(value.descriptorSchemaID) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "negotiatedCapabilities.descriptorSchemaID"
            )
        }
        guard value.hasEncoding else {
            throw HarcProtobufConversionError.missingField(
                "negotiatedCapabilities.encoding"
            )
        }
        let encoding = try value.encoding.domainValue()
        guard policy.supportedEncodings.contains(encoding),
              policy.allowRawPCMFixture || encoding != .rawPCMFixture else {
            throw HarcProtobufConversionError.invalidValue(
                field: "negotiatedCapabilities.encoding"
            )
        }
        guard value.hasCanonicalFormat else {
            throw HarcProtobufConversionError.missingField(
                "negotiatedCapabilities.canonicalFormat"
            )
        }
        let format = try value.canonicalFormat.domainValue()
        guard policy.supportedCanonicalFormats.contains(format) else {
            throw HarcProtobufConversionError.invalidValue(
                field: "negotiatedCapabilities.canonicalFormat"
            )
        }

        self.exactPayload = exactPayload
        self.exactSHA256 = digest
        self.protocolVersion = version
        self.requirements = requirements
        self.selectedFeatureIDs = value.selectedFeatureIds
        self.descriptorSchemaID = value.descriptorSchemaID
        self.encoding = encoding
        self.canonicalFormat = format
    }

    public func validateSelection(
        clientOffer: HarcValidatedCapabilityOfferV1,
        hostOffer: HarcValidatedCapabilityOfferV1
    ) throws {
        guard protocolVersion.major == clientOffer.protocolMajor,
              protocolVersion.major == hostOffer.protocolMajor,
              (clientOffer.minimumProtocolMinor ... clientOffer.maximumProtocolMinor)
                .contains(protocolVersion.minor),
              (hostOffer.minimumProtocolMinor ... hostOffer.maximumProtocolMinor)
                .contains(protocolVersion.minor) else {
            throw HarcProtobufConversionError.inconsistentField(
                "negotiatedCapabilities.protocolVersion"
            )
        }
        for feature in selectedFeatureIDs {
            guard clientOffer.supportedFeatureIDs.contains(feature),
                  hostOffer.supportedFeatureIDs.contains(feature) else {
                throw HarcProtobufConversionError.inconsistentField(
                    "negotiatedCapabilities.selectedFeatureIDs"
                )
            }
        }
        guard clientOffer.supportedDescriptorSchemaIDs.contains(descriptorSchemaID),
              hostOffer.supportedDescriptorSchemaIDs.contains(descriptorSchemaID),
              clientOffer.supportedEncodings.contains(encoding),
              hostOffer.supportedEncodings.contains(encoding),
              clientOffer.supportedCanonicalFormats.contains(canonicalFormat),
              hostOffer.supportedCanonicalFormats.contains(canonicalFormat) else {
            throw HarcProtobufConversionError.inconsistentField(
                "negotiatedCapabilities.selection"
            )
        }
    }
}

private func harcValidateCapabilityCodes(_ values: [String], field: String) throws {
    guard values == values.sorted() else {
        throw HarcProtobufConversionError.nonCanonicalOrder(field: field)
    }
    guard Set(values).count == values.count else {
        throw HarcProtobufConversionError.duplicateValue(field: field)
    }
    for value in values {
        try harcValidateCapabilityCode(value, field: field)
    }
}

private func harcValidateCapabilityCode(_ value: String, field: String) throws {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard !value.isEmpty, value.utf8.count <= 128,
          value.unicodeScalars.allSatisfy(allowed.contains) else {
        throw HarcProtobufConversionError.invalidValue(field: field)
    }
}

private func harcRequireCanonicalCapabilityEncodings(
    _ values: [LosslessEncodingConfiguration]
) throws {
    let keys = values.map { value in
        [
            value.codec.rawValue,
            value.container.rawValue,
            value.flacCompressionLevel.map(String.init) ?? "-",
        ].joined(separator: "|")
    }
    guard keys == keys.sorted() else {
        throw HarcProtobufConversionError.nonCanonicalOrder(
            field: "capabilityOffer.supportedEncodings"
        )
    }
    guard Set(values).count == values.count else {
        throw HarcProtobufConversionError.duplicateValue(
            field: "capabilityOffer.supportedEncodings"
        )
    }
}

private func harcRequireCanonicalCapabilityFormats(
    _ values: [CanonicalPCMFormat]
) throws {
    let keys = values.map { value in
        String(format: "%010u|%05u|%@", value.sampleRateHz, value.channelCount, value.encoding.rawValue)
    }
    guard keys == keys.sorted() else {
        throw HarcProtobufConversionError.nonCanonicalOrder(
            field: "capabilityOffer.supportedCanonicalFormats"
        )
    }
    guard Set(values).count == values.count else {
        throw HarcProtobufConversionError.duplicateValue(
            field: "capabilityOffer.supportedCanonicalFormats"
        )
    }
}
