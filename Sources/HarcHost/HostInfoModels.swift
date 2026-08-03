import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

/// Protocol-neutral projection of one frozen capability offer. The transport
/// adapter remains responsible for protobuf decoding/encoding and protocol
/// compatibility policy; HarcHost retains only the validated semantic facts it
/// must advertise and bind into negotiation.
public struct HostInfoCapabilityOffer: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let minimumProtocolMinor: UInt16
    public let maximumProtocolMinor: UInt16
    public let requiredFeatureIDs: [String]
    public let criticalFieldNumbers: [UInt32]
    public let supportedFeatureIDs: [String]
    public let supportedDescriptorSchemaIDs: [String]
    public let supportedEncodings: [LosslessEncodingConfiguration]
    public let supportedCanonicalFormats: [CanonicalPCMFormat]

    public init(
        protocolMajor: UInt16,
        minimumProtocolMinor: UInt16,
        maximumProtocolMinor: UInt16,
        requiredFeatureIDs: [String] = [],
        criticalFieldNumbers: [UInt32] = [],
        supportedFeatureIDs: [String],
        supportedDescriptorSchemaIDs: [String],
        supportedEncodings: [LosslessEncodingConfiguration],
        supportedCanonicalFormats: [CanonicalPCMFormat]
    ) throws {
        guard minimumProtocolMinor <= maximumProtocolMinor else {
            throw HarcHostError.invalidHostInfoInput("capability protocol range")
        }
        try Self.requireCanonicalCodes(
            requiredFeatureIDs,
            field: "required feature identifiers"
        )
        try Self.requireCanonicalCodes(
            supportedFeatureIDs,
            field: "supported feature identifiers"
        )
        try Self.requireCanonicalCodes(
            supportedDescriptorSchemaIDs,
            field: "descriptor schema identifiers"
        )
        guard !supportedDescriptorSchemaIDs.isEmpty,
              !supportedEncodings.isEmpty,
              !supportedCanonicalFormats.isEmpty else {
            throw HarcHostError.invalidHostInfoInput("capability selection sets")
        }
        guard criticalFieldNumbers == criticalFieldNumbers.sorted(),
              Set(criticalFieldNumbers).count == criticalFieldNumbers.count,
              criticalFieldNumbers.allSatisfy(Self.isValidProtobufFieldNumber) else {
            throw HarcHostError.invalidHostInfoInput("critical field numbers")
        }
        guard Self.encodingKeys(supportedEncodings)
                == Self.encodingKeys(supportedEncodings).sorted(),
              Set(supportedEncodings).count == supportedEncodings.count else {
            throw HarcHostError.invalidHostInfoInput("supported encodings")
        }
        guard Self.formatKeys(supportedCanonicalFormats)
                == Self.formatKeys(supportedCanonicalFormats).sorted(),
              Set(supportedCanonicalFormats).count
                == supportedCanonicalFormats.count else {
            throw HarcHostError.invalidHostInfoInput("canonical formats")
        }

        self.protocolMajor = protocolMajor
        self.minimumProtocolMinor = minimumProtocolMinor
        self.maximumProtocolMinor = maximumProtocolMinor
        self.requiredFeatureIDs = requiredFeatureIDs
        self.criticalFieldNumbers = criticalFieldNumbers
        self.supportedFeatureIDs = supportedFeatureIDs
        self.supportedDescriptorSchemaIDs = supportedDescriptorSchemaIDs
        self.supportedEncodings = supportedEncodings
        self.supportedCanonicalFormats = supportedCanonicalFormats
    }

    public func supports(protocolMajor: UInt16, protocolMinor: UInt16) -> Bool {
        self.protocolMajor == protocolMajor
            && (minimumProtocolMinor ... maximumProtocolMinor)
                .contains(protocolMinor)
    }

    private static func requireCanonicalCodes(
        _ values: [String],
        field: String
    ) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard values == values.sorted(),
              Set(values).count == values.count,
              values.allSatisfy({ value in
                  !value.isEmpty
                      && value.utf8.count <= 128
                      && value.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw HarcHostError.invalidHostInfoInput(field)
        }
    }

    private static func encodingKeys(
        _ values: [LosslessEncodingConfiguration]
    ) -> [String] {
        values.map {
            [
                $0.codec.rawValue,
                $0.container.rawValue,
                $0.flacCompressionLevel.map(String.init) ?? "-",
            ].joined(separator: "|")
        }
    }

    private static func formatKeys(_ values: [CanonicalPCMFormat]) -> [String] {
        values.map {
            String(
                format: "%010u|%05u|%@",
                $0.sampleRateHz,
                $0.channelCount,
                $0.encoding.rawValue
            )
        }
    }

    private static func isValidProtobufFieldNumber(_ value: UInt32) -> Bool {
        value > 0
            && value <= 536_870_911
            && !(19_000 ... 19_999).contains(value)
    }
}

public struct GetHostInfoRequest: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let source: HostPreauthenticationSource

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        source: HostPreauthenticationSource
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.source = source
    }
}

public struct GetHostInfoResponse: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let displayName: String
    public let libraryID: LibraryID
    public let hostAuthorityID: HostAuthorityID
    public let hostAuthorityPublicKey: P256X963PublicKey
    public let offers: [HostInfoCapabilityOffer]
    public let exactSignedTransportSet: Data
    public let serverTime: Date
}

public struct NegotiateHostCapabilitiesRequest: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let clientOffer: HostInfoCapabilityOffer
    public let source: HostPreauthenticationSource

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        clientOffer: HostInfoCapabilityOffer,
        source: HostPreauthenticationSource
    ) throws {
        guard clientOffer.supports(
            protocolMajor: protocolMajor,
            protocolMinor: protocolMinor
        ) else {
            throw HarcHostError.invalidHostInfoInput(
                "negotiation protocol and client offer"
            )
        }
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.clientOffer = clientOffer
        self.source = source
    }
}

public struct NegotiateHostCapabilitiesResponse: Equatable, Sendable {
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let exactNegotiatedCapabilities: Data
    public let negotiatedCapabilitiesSHA256: Data
    public let exactSignedTransportSet: Data
    public let serverTime: Date
}
