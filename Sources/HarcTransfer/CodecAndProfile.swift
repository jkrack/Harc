import Foundation
import HarcDomain

public enum LosslessAudioCodec: String, Codable, CaseIterable, Sendable {
    case appleLossless = "alac"
    case flac = "flac"
    case rawCanonicalPCMFixture = "raw-pcm-s16le-fixture"
}

public enum LosslessAudioContainer: String, Codable, CaseIterable, Sendable {
    case coreAudioFormat = "caf"
    case flac = "flac"
    case rawCanonicalPCMFixture = "raw-pcm-fixture"
}

public enum UploadProfilePurpose: String, Codable, CaseIterable, Sendable {
    case production
    case physicalDeviceCodecEvaluation
    case fixtureLoopback
}

/// An exact V1 encoder selection. Codec/container compatibility is represented
/// as a validated value rather than two independently mutable strings.
public struct LosslessEncodingConfiguration: Codable, Equatable, Hashable, Sendable {
    public let codec: LosslessAudioCodec
    public let container: LosslessAudioContainer

    /// Frozen FLAC encoder level (0...12). It is nil for ALAC and fixture PCM.
    public let flacCompressionLevel: UInt8?

    public init(
        codec: LosslessAudioCodec,
        container: LosslessAudioContainer,
        flacCompressionLevel: UInt8? = nil
    ) throws {
        switch (codec, container) {
        case (.appleLossless, .coreAudioFormat):
            guard flacCompressionLevel == nil else {
                throw TransferValidationError.invalidCodecParameters(
                    reason: "ALAC does not accept a FLAC compression level."
                )
            }
        case (.flac, .flac):
            guard let flacCompressionLevel, flacCompressionLevel <= 12 else {
                throw TransferValidationError.invalidCodecParameters(
                    reason: "FLAC requires a frozen compression level from 0 through 12."
                )
            }
        case (.rawCanonicalPCMFixture, .rawCanonicalPCMFixture):
            guard flacCompressionLevel == nil else {
                throw TransferValidationError.invalidCodecParameters(
                    reason: "Raw fixture PCM has no codec parameters."
                )
            }
        default:
            throw TransferValidationError.incompatibleCodecAndContainer
        }

        self.codec = codec
        self.container = container
        self.flacCompressionLevel = flacCompressionLevel
    }

    public static let cafALAC = try! Self(codec: .appleLossless, container: .coreAudioFormat)

    public static func flac(compressionLevel: UInt8) throws -> Self {
        try Self(codec: .flac, container: .flac, flacCompressionLevel: compressionLevel)
    }

    public static let rawPCMFixture = try! Self(
        codec: .rawCanonicalPCMFixture,
        container: .rawCanonicalPCMFixture
    )

    public var isProductionEligible: Bool { codec != .rawCanonicalPCMFixture }

    private enum CodingKeys: String, CodingKey {
        case codec
        case container
        case flacCompressionLevel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                codec: container.decode(LosslessAudioCodec.self, forKey: .codec),
                container: container.decode(LosslessAudioContainer.self, forKey: .container),
                flacCompressionLevel: container.decodeIfPresent(UInt8.self, forKey: .flacCompressionLevel)
            )
        } catch {
            throw TransferValidation.decodingFailure(
                error,
                codingPath: decoder.codingPath,
                description: "Invalid lossless encoding configuration."
            )
        }
    }
}

public struct TransferProtocolVersion: Codable, Equatable, Hashable, Sendable {
    public static let harcV1Major: UInt16 = 1

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16 = Self.harcV1Major, minor: UInt16) throws {
        guard major == Self.harcV1Major else {
            throw TransferValidationError.invalidUploadAttempt(reason: "HarcTransfer supports protocol major 1 only.")
        }
        self.major = major
        self.minor = minor
    }

    private enum CodingKeys: String, CodingKey { case major, minor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                major: container.decode(UInt16.self, forKey: .major),
                minor: container.decode(UInt16.self, forKey: .minor)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid transfer protocol version.")
        }
    }
}

public enum ChunkDescriptorSchema: String, Codable, CaseIterable, Sendable {
    case v1 = "harc.chunk-descriptor.v1"
}

public struct TransferCapabilityID: Codable, Equatable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        self.rawValue = try TransferValidation.normalizedCode(rawValue, field: "TransferCapabilityID")
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode(String.self)) }
        catch { throw TransferValidation.decodingFailure(error, codingPath: container.codingPath, description: "Invalid transfer capability identifier.") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A typed projection of one exact `UploadProfileV1`, bound to the SHA-256 of
/// its exact future wire bytes. HarcProtocol is responsible for proving that
/// binding when protobuf lands; this module freezes and compares every semantic
/// field without serializing a wire format of its own.
public struct FrozenUploadProfile: Codable, Equatable, Hashable, Sendable {
    public let protocolVersion: TransferProtocolVersion
    public let descriptorSchema: ChunkDescriptorSchema
    public let encoding: LosslessEncodingConfiguration
    public let canonicalFormat: CanonicalPCMFormat
    public let requiredCapabilities: [TransferCapabilityID]
    public let negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256
    public let profileSHA256: UploadProfileSHA256
    public let purpose: UploadProfilePurpose

    public init(
        protocolVersion: TransferProtocolVersion,
        descriptorSchema: ChunkDescriptorSchema = .v1,
        encoding: LosslessEncodingConfiguration,
        canonicalFormat: CanonicalPCMFormat = .harcV1,
        requiredCapabilities: [TransferCapabilityID],
        negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256,
        profileSHA256: UploadProfileSHA256,
        purpose: UploadProfilePurpose
    ) throws {
        try TransferValidation.requireHarcV1(canonicalFormat)

        guard requiredCapabilities == requiredCapabilities.sorted() else {
            throw TransferValidationError.invalidOrdering(field: "FrozenUploadProfile.requiredCapabilities")
        }
        guard Set(requiredCapabilities).count == requiredCapabilities.count else {
            throw TransferValidationError.duplicateIdentifier(field: "FrozenUploadProfile.requiredCapabilities")
        }

        if purpose != .fixtureLoopback, !encoding.isProductionEligible {
            throw TransferValidationError.rawPCMRestrictedToFixtures
        }
        if purpose == .fixtureLoopback {
            // Loopback may still exercise a production codec. Raw is merely
            // restricted to this purpose, not required by it.
        }

        self.protocolVersion = protocolVersion
        self.descriptorSchema = descriptorSchema
        self.encoding = encoding
        self.canonicalFormat = canonicalFormat
        self.requiredCapabilities = requiredCapabilities
        self.negotiatedCapabilitiesSHA256 = negotiatedCapabilitiesSHA256
        self.profileSHA256 = profileSHA256
        self.purpose = purpose
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case descriptorSchema
        case encoding
        case canonicalFormat
        case requiredCapabilities
        case negotiatedCapabilitiesSHA256
        case profileSHA256
        case purpose
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                protocolVersion: container.decode(TransferProtocolVersion.self, forKey: .protocolVersion),
                descriptorSchema: container.decode(ChunkDescriptorSchema.self, forKey: .descriptorSchema),
                encoding: container.decode(LosslessEncodingConfiguration.self, forKey: .encoding),
                canonicalFormat: container.decode(CanonicalPCMFormat.self, forKey: .canonicalFormat),
                requiredCapabilities: container.decode([TransferCapabilityID].self, forKey: .requiredCapabilities),
                negotiatedCapabilitiesSHA256: container.decode(NegotiatedCapabilitiesSHA256.self, forKey: .negotiatedCapabilitiesSHA256),
                profileSHA256: container.decode(UploadProfileSHA256.self, forKey: .profileSHA256),
                purpose: container.decode(UploadProfilePurpose.self, forKey: .purpose)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid frozen upload profile.")
        }
    }
}
