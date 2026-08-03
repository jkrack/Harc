import Foundation
import HarcDomain

/// Immutable metadata for one independently decodable logical PCM frame range.
public struct LogicalChunkDescriptor: Codable, Equatable, Hashable, Sendable {
    public let originRecordingID: OriginRecordingID
    public let chunkID: ChunkID
    public let chunkIndex: UInt32
    public let canonicalStartFrame: UInt64
    public let canonicalFrameCount: UInt64
    public let canonicalEndFrameExclusive: UInt64
    public let canonicalFormat: CanonicalPCMFormat
    public let encoding: LosslessEncodingConfiguration
    public let encodedByteLength: UInt64
    public let encodedSHA256: EncodedChunkSHA256
    public let canonicalDecodedByteLength: UInt64
    public let canonicalDecodedSHA256: CanonicalPCMHash

    public init(
        originRecordingID: OriginRecordingID,
        chunkID: ChunkID,
        chunkIndex: UInt32,
        canonicalStartFrame: UInt64,
        canonicalFrameCount: UInt64,
        canonicalFormat: CanonicalPCMFormat = .harcV1,
        encoding: LosslessEncodingConfiguration,
        encodedByteLength: UInt64,
        encodedSHA256: EncodedChunkSHA256,
        canonicalDecodedByteLength: UInt64,
        canonicalDecodedSHA256: CanonicalPCMHash
    ) throws {
        try TransferValidation.requireHarcV1(canonicalFormat)
        guard canonicalFrameCount > 0 else {
            throw TransferValidationError.invalidLength(
                field: "LogicalChunkDescriptor.canonicalFrameCount",
                value: canonicalFrameCount
            )
        }
        guard canonicalFrameCount <= TransferLimits.ordinaryChunkFrames else {
            throw TransferValidationError.exceedsLimit(
                field: "LogicalChunkDescriptor.canonicalFrameCount",
                limit: TransferLimits.ordinaryChunkFrames,
                actual: canonicalFrameCount
            )
        }
        let endFrame = try TransferValidation.adding(
            canonicalStartFrame,
            canonicalFrameCount,
            field: "LogicalChunkDescriptor.canonicalEndFrameExclusive"
        )
        guard encodedByteLength > 0 else {
            throw TransferValidationError.invalidLength(
                field: "LogicalChunkDescriptor.encodedByteLength",
                value: encodedByteLength
            )
        }
        guard encodedByteLength <= TransferLimits.encodedChunkBytes else {
            throw TransferValidationError.exceedsLimit(
                field: "LogicalChunkDescriptor.encodedByteLength",
                limit: TransferLimits.encodedChunkBytes,
                actual: encodedByteLength
            )
        }
        let expectedDecodedBytes = try TransferValidation.canonicalByteCount(forFrames: canonicalFrameCount)
        guard canonicalDecodedByteLength == expectedDecodedBytes else {
            throw TransferValidationError.inconsistentCanonicalByteCount(
                expected: expectedDecodedBytes,
                actual: canonicalDecodedByteLength
            )
        }
        if encoding == .rawPCMFixture {
            guard encodedByteLength == canonicalDecodedByteLength,
                  encodedSHA256.rawBytes == canonicalDecodedSHA256.rawBytes else {
                throw TransferValidationError.invalidCodecParameters(
                    reason: "Raw fixture bytes and SHA-256 must equal the canonical decoded bytes and SHA-256."
                )
            }
        }

        self.originRecordingID = originRecordingID
        self.chunkID = chunkID
        self.chunkIndex = chunkIndex
        self.canonicalStartFrame = canonicalStartFrame
        self.canonicalFrameCount = canonicalFrameCount
        self.canonicalEndFrameExclusive = endFrame
        self.canonicalFormat = canonicalFormat
        self.encoding = encoding
        self.encodedByteLength = encodedByteLength
        self.encodedSHA256 = encodedSHA256
        self.canonicalDecodedByteLength = canonicalDecodedByteLength
        self.canonicalDecodedSHA256 = canonicalDecodedSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case originRecordingID
        case chunkID
        case chunkIndex
        case canonicalStartFrame
        case canonicalFrameCount
        case canonicalFormat
        case encoding
        case encodedByteLength
        case encodedSHA256
        case canonicalDecodedByteLength
        case canonicalDecodedSHA256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                originRecordingID: container.decode(OriginRecordingID.self, forKey: .originRecordingID),
                chunkID: container.decode(ChunkID.self, forKey: .chunkID),
                chunkIndex: container.decode(UInt32.self, forKey: .chunkIndex),
                canonicalStartFrame: container.decode(UInt64.self, forKey: .canonicalStartFrame),
                canonicalFrameCount: container.decode(UInt64.self, forKey: .canonicalFrameCount),
                canonicalFormat: container.decode(CanonicalPCMFormat.self, forKey: .canonicalFormat),
                encoding: container.decode(LosslessEncodingConfiguration.self, forKey: .encoding),
                encodedByteLength: container.decode(UInt64.self, forKey: .encodedByteLength),
                encodedSHA256: container.decode(EncodedChunkSHA256.self, forKey: .encodedSHA256),
                canonicalDecodedByteLength: container.decode(UInt64.self, forKey: .canonicalDecodedByteLength),
                canonicalDecodedSHA256: container.decode(CanonicalPCMHash.self, forKey: .canonicalDecodedSHA256)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid logical chunk descriptor.")
        }
    }
}

/// A host-neutral finalized capture with a complete independently decodable
/// chunk set. It can be projected into a host-bound manifest later without
/// changing capture identity or PCM facts.
public struct ChunkedFinalizedCapture: Codable, Equatable, Hashable, Sendable {
    public let capture: FinalizedCapture
    public let chunks: [LogicalChunkDescriptor]
    public let encoding: LosslessEncodingConfiguration

    public init(capture: FinalizedCapture, chunks: [LogicalChunkDescriptor]) throws {
        guard let first = chunks.first else {
            throw TransferValidationError.incompleteChunkCoverage(
                expectedFrames: capture.totalCanonicalFrames,
                actualFrames: 0
            )
        }

        var expectedIndex: UInt32 = 0
        var expectedStart: UInt64 = 0
        var identifiers = Set<ChunkID>()
        for chunk in chunks {
            guard chunk.originRecordingID == capture.originRecordingID else {
                throw TransferValidationError.profileMismatch(field: "originRecordingID")
            }
            guard chunk.canonicalFormat == capture.canonicalFormat else {
                throw TransferValidationError.profileMismatch(field: "canonicalFormat")
            }
            guard chunk.encoding == first.encoding else {
                throw TransferValidationError.profileMismatch(field: "encoding")
            }
            guard chunk.chunkIndex == expectedIndex,
                  chunk.canonicalStartFrame == expectedStart else {
                throw TransferValidationError.nonContiguousDeclaration(
                    expectedIndex: expectedIndex,
                    expectedStartFrame: expectedStart
                )
            }
            guard identifiers.insert(chunk.chunkID).inserted else {
                throw TransferValidationError.duplicateIdentifier(field: "ChunkedFinalizedCapture.chunks")
            }
            expectedStart = chunk.canonicalEndFrameExclusive
            expectedIndex = try TransferValidation.next(expectedIndex, field: "ChunkedFinalizedCapture.chunkIndex")
        }
        guard expectedStart == capture.totalCanonicalFrames else {
            throw TransferValidationError.incompleteChunkCoverage(
                expectedFrames: capture.totalCanonicalFrames,
                actualFrames: expectedStart
            )
        }

        self.capture = capture
        self.chunks = chunks
        self.encoding = first.encoding
    }

    public func validate(against profile: FrozenUploadProfile) throws {
        guard profile.encoding == encoding else {
            throw TransferValidationError.profileMismatch(field: "encoding")
        }
        guard profile.canonicalFormat == capture.canonicalFormat else {
            throw TransferValidationError.profileMismatch(field: "canonicalFormat")
        }
    }

    private enum CodingKeys: String, CodingKey { case capture, chunks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                capture: container.decode(FinalizedCapture.self, forKey: .capture),
                chunks: container.decode([LogicalChunkDescriptor].self, forKey: .chunks)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid chunked finalized capture.")
        }
    }
}
