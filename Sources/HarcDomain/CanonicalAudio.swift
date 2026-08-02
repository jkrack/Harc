import Foundation

public enum CanonicalPCMEncoding: String, Codable, CaseIterable, Sendable {
    case signedInt16LittleEndian
}

public struct CanonicalPCMFormat: Codable, Equatable, Hashable, Sendable {
    public let sampleRateHz: UInt32
    public let channelCount: UInt16
    public let encoding: CanonicalPCMEncoding

    public init(
        sampleRateHz: UInt32,
        channelCount: UInt16,
        encoding: CanonicalPCMEncoding
    ) throws {
        guard sampleRateHz > 0 else {
            throw DomainValidationError.invalidState(reason: "Canonical PCM sample rate must be nonzero.")
        }
        guard channelCount > 0 else {
            throw DomainValidationError.invalidState(reason: "Canonical PCM channel count must be nonzero.")
        }
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.encoding = encoding
    }

    public static let harcV1 = try! CanonicalPCMFormat(
        sampleRateHz: 16_000,
        channelCount: 1,
        encoding: .signedInt16LittleEndian
    )

    private enum CodingKeys: String, CodingKey {
        case sampleRateHz
        case channelCount
        case encoding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                sampleRateHz: container.decode(UInt32.self, forKey: .sampleRateHz),
                channelCount: container.decode(UInt16.self, forKey: .channelCount),
                encoding: container.decode(CanonicalPCMEncoding.self, forKey: .encoding)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid canonical PCM format.",
                    underlyingError: error
                )
            )
        }
    }
}

public enum CanonicalAudioAvailability: String, Codable, CaseIterable, Sendable {
    case unavailablePendingHash
    case available
}

/// A path-free description of canonical audio readiness.
public struct CanonicalAudioDescriptor: Codable, Equatable, Hashable, Sendable {
    public let availability: CanonicalAudioAvailability
    public let pcmSHA256: CanonicalPCMHash?
    public let totalFrames: UInt64?
    public let format: CanonicalPCMFormat?

    public static let unavailablePendingHash = try! CanonicalAudioDescriptor(
        availability: .unavailablePendingHash
    )

    public init(
        availability: CanonicalAudioAvailability,
        pcmSHA256: CanonicalPCMHash? = nil,
        totalFrames: UInt64? = nil,
        format: CanonicalPCMFormat? = nil
    ) throws {
        switch availability {
        case .unavailablePendingHash:
            guard pcmSHA256 == nil, totalFrames == nil, format == nil else {
                throw DomainValidationError.invalidState(
                    reason: "Unavailable canonical audio cannot claim a hash, frame count, or format."
                )
            }
        case .available:
            guard pcmSHA256 != nil, let totalFrames, totalFrames > 0, format != nil else {
                throw DomainValidationError.invalidState(
                    reason: "Available canonical audio requires a hash, positive frame count, and format."
                )
            }
        }

        self.availability = availability
        self.pcmSHA256 = pcmSHA256
        self.totalFrames = totalFrames
        self.format = format
    }

    public static func available(
        pcmSHA256: CanonicalPCMHash,
        totalFrames: UInt64,
        format: CanonicalPCMFormat = .harcV1
    ) throws -> Self {
        try Self(
            availability: .available,
            pcmSHA256: pcmSHA256,
            totalFrames: totalFrames,
            format: format
        )
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case pcmSHA256
        case totalFrames
        case format
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                availability: container.decode(CanonicalAudioAvailability.self, forKey: .availability),
                pcmSHA256: container.decodeIfPresent(CanonicalPCMHash.self, forKey: .pcmSHA256),
                totalFrames: container.decodeIfPresent(UInt64.self, forKey: .totalFrames),
                format: container.decodeIfPresent(CanonicalPCMFormat.self, forKey: .format)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid canonical audio descriptor.",
                    underlyingError: error
                )
            )
        }
    }
}
