import Foundation
import HarcDomain

/// Metadata for an immutable background batch body. Framing and protobuf header
/// bytes remain a HarcProtocol concern; this value is safe to persist before a
/// transport task is scheduled and contains no task identifier or URL.
public struct ImmutableAudioBatchDescriptor: Codable, Equatable, Hashable, Sendable {
    public let batchID: AudioBatchID
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let originRecordingID: OriginRecordingID
    public let ownerDeviceID: DeviceID
    public let chunks: [LogicalChunkDescriptor]
    public let exactBodyByteLength: UInt64
    public let exactBodySHA256: ImmutableBatchSHA256

    public init(
        batchID: AudioBatchID,
        uploadID: UploadID,
        generation: UploadGeneration,
        uploadProfileSHA256: UploadProfileSHA256,
        originRecordingID: OriginRecordingID,
        ownerDeviceID: DeviceID,
        chunks: [LogicalChunkDescriptor],
        exactBodyByteLength: UInt64,
        exactBodySHA256: ImmutableBatchSHA256
    ) throws {
        guard originRecordingID.deviceID == ownerDeviceID else {
            throw TransferValidationError.originDeviceMismatch
        }
        guard !chunks.isEmpty else {
            throw TransferValidationError.invalidLength(field: "ImmutableAudioBatchDescriptor.chunks", value: 0)
        }
        guard chunks.count <= TransferLimits.backgroundBatchEntries else {
            throw TransferValidationError.exceedsLimit(
                field: "ImmutableAudioBatchDescriptor.chunks",
                limit: UInt64(TransferLimits.backgroundBatchEntries),
                actual: UInt64(chunks.count)
            )
        }
        guard exactBodyByteLength > 0 else {
            throw TransferValidationError.invalidLength(field: "ImmutableAudioBatchDescriptor.exactBodyByteLength", value: exactBodyByteLength)
        }
        guard exactBodyByteLength <= TransferLimits.backgroundBatchBytes else {
            throw TransferValidationError.exceedsLimit(
                field: "ImmutableAudioBatchDescriptor.exactBodyByteLength",
                limit: TransferLimits.backgroundBatchBytes,
                actual: exactBodyByteLength
            )
        }

        var priorIndex: UInt32?
        var seen = Set<ChunkID>()
        var minimumBodyBytes: UInt64 = 13 // magic + header-length + nonempty header
        for chunk in chunks {
            guard chunk.originRecordingID == originRecordingID else {
                throw TransferValidationError.profileMismatch(field: "originRecordingID")
            }
            if let priorIndex, chunk.chunkIndex <= priorIndex {
                throw TransferValidationError.invalidOrdering(field: "ImmutableAudioBatchDescriptor.chunks")
            }
            guard seen.insert(chunk.chunkID).inserted else {
                throw TransferValidationError.duplicateIdentifier(field: "ImmutableAudioBatchDescriptor.chunks")
            }
            minimumBodyBytes = try TransferValidation.adding(
                minimumBodyBytes,
                4,
                field: "ImmutableAudioBatchDescriptor framing"
            )
            minimumBodyBytes = try TransferValidation.adding(
                minimumBodyBytes,
                chunk.encodedByteLength,
                field: "ImmutableAudioBatchDescriptor framing"
            )
            priorIndex = chunk.chunkIndex
        }
        guard exactBodyByteLength >= minimumBodyBytes else {
            throw TransferValidationError.invalidLength(
                field: "ImmutableAudioBatchDescriptor.exactBodyByteLength",
                value: exactBodyByteLength
            )
        }

        self.batchID = batchID
        self.uploadID = uploadID
        self.generation = generation
        self.uploadProfileSHA256 = uploadProfileSHA256
        self.originRecordingID = originRecordingID
        self.ownerDeviceID = ownerDeviceID
        self.chunks = chunks
        self.exactBodyByteLength = exactBodyByteLength
        self.exactBodySHA256 = exactBodySHA256
    }

    private enum CodingKeys: String, CodingKey {
        case batchID
        case uploadID
        case generation
        case uploadProfileSHA256
        case originRecordingID
        case ownerDeviceID
        case chunks
        case exactBodyByteLength
        case exactBodySHA256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                batchID: container.decode(AudioBatchID.self, forKey: .batchID),
                uploadID: container.decode(UploadID.self, forKey: .uploadID),
                generation: container.decode(UploadGeneration.self, forKey: .generation),
                uploadProfileSHA256: container.decode(UploadProfileSHA256.self, forKey: .uploadProfileSHA256),
                originRecordingID: container.decode(OriginRecordingID.self, forKey: .originRecordingID),
                ownerDeviceID: container.decode(DeviceID.self, forKey: .ownerDeviceID),
                chunks: container.decode([LogicalChunkDescriptor].self, forKey: .chunks),
                exactBodyByteLength: container.decode(UInt64.self, forKey: .exactBodyByteLength),
                exactBodySHA256: container.decode(ImmutableBatchSHA256.self, forKey: .exactBodySHA256)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid immutable audio batch descriptor.")
        }
    }
}
