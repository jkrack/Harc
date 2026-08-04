import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientTransport
import HarcDomain
import HarcProtocol
import HarcTransfer

enum HarcMobileBackgroundBatchError: Error, Equatable, Sendable {
    case invalidChunkFile(UInt32)
    case batchTooLarge
}

/// Production HARCAB1 builder for stopped iPhone recordings.
///
/// Groups are deterministic and bounded below the eight-MiB initial batch
/// policy. Each exact body is synchronized, atomically published, protected for
/// after-first-unlock access, and excluded from backup before it is returned to
/// the URLSession scheduler.
struct HarcMobileBackgroundBatchPreparer:
    HarcBackgroundAudioBatchPreparingV1, Sendable
{
    private static let targetExactBytes = 8 * 1_024 * 1_024
    private static let payloadBudget = 7 * 1_024 * 1_024
    private static let maximumChunksPerBatch = 10

    let locations: HarcMobileCaptureLocations
    let attributes: any HarcMobileCaptureStorageAttributeApplying

    init(
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying =
            FoundationHarcMobileCaptureStorageAttributes()
    ) {
        self.locations = locations
        self.attributes = attributes
    }

    func prepareBatches(
        plan: HarcForegroundRecordingUploadPlan,
        generation: UploadGeneration,
        chunks: [HarcForegroundEncodedChunk]
    ) async throws -> [HarcPreparedBackgroundAudioBatchV1] {
        try locations.prepare(attributes: attributes)
        let directory = locations.root.appendingPathComponent(
            "BackgroundBatches",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try attributes.applyAndVerify(
            .transferArtifact,
            to: directory
        )

        var groups: [[HarcForegroundEncodedChunk]] = []
        var current: [HarcForegroundEncodedChunk] = []
        var currentBytes = 0
        for chunk in chunks {
            guard let encodedBytes = Int(exactly:
                chunk.descriptor.encodedByteLength
            ) else {
                throw HarcMobileBackgroundBatchError.invalidChunkFile(
                    chunk.descriptor.chunkIndex
                )
            }
            let framedBytes = encodedBytes + 4
            if !current.isEmpty,
               current.count == Self.maximumChunksPerBatch
                || currentBytes + framedBytes > Self.payloadBudget {
                groups.append(current)
                current = []
                currentBytes = 0
            }
            current.append(chunk)
            currentBytes += framedBytes
        }
        if !current.isEmpty { groups.append(current) }

        return try groups.map { group in
            try prepareBatch(
                plan: plan,
                generation: generation,
                chunks: group,
                directory: directory
            )
        }
    }

    private func prepareBatch(
        plan: HarcForegroundRecordingUploadPlan,
        generation: UploadGeneration,
        chunks: [HarcForegroundEncodedChunk],
        directory: URL
    ) throws -> HarcPreparedBackgroundAudioBatchV1 {
        let encoded = try chunks.map { chunk in
            let bytes = try Data(
                contentsOf: chunk.encodedFileURL,
                options: .mappedIfSafe
            )
            guard UInt64(bytes.count) == chunk.descriptor.encodedByteLength,
                  Data(SHA256.hash(data: bytes))
                    == chunk.descriptor.encodedSHA256.rawBytes else {
                throw HarcMobileBackgroundBatchError.invalidChunkFile(
                    chunk.descriptor.chunkIndex
                )
            }
            return bytes
        }
        let batchID = Self.batchID(
            uploadID: plan.uploadID,
            generation: generation,
            chunks: chunks.map(\.descriptor)
        )
        var header = Harc_V1_AudioBatchHeaderV1()
        header.protocol.major = UInt32(
            plan.frozenProfile.protocolVersion.major
        )
        header.protocol.minor = UInt32(
            plan.frozenProfile.protocolVersion.minor
        )
        header.batchID = Harc_V1_AudioBatchIDV1(batchID)
        header.uploadID = Harc_V1_UploadIDV1(plan.uploadID)
        header.uploadProfileSha256 = try Harc_V1_SHA256DigestV1(
            exactBytes: plan.frozenProfile.profileSHA256.rawBytes
        )
        header.originRecordingID = Harc_V1_OriginRecordingIDV1(
            plan.originRecordingID
        )
        header.deviceID = Harc_V1_DeviceIDV1(
            plan.originRecordingID.deviceID
        )
        header.entries = try chunks.map { chunk in
            let descriptor = chunk.descriptor
            guard let encodedLength = UInt32(exactly:
                descriptor.encodedByteLength
            ) else {
                throw HarcMobileBackgroundBatchError.invalidChunkFile(
                    descriptor.chunkIndex
                )
            }
            var entry = Harc_V1_AudioBatchEntryV1()
            entry.chunkID = Harc_V1_ChunkIDV1(descriptor.chunkID)
            entry.chunkIndex = descriptor.chunkIndex
            entry.encodedLength = encodedLength
            entry.encodedSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: descriptor.encodedSHA256.rawBytes
            )
            entry.canonicalStartFrame = descriptor.canonicalStartFrame
            entry.canonicalFrameCount = descriptor.canonicalFrameCount
            entry.canonicalDecodedSha256 = try Harc_V1_SHA256DigestV1(
                exactBytes: descriptor.canonicalDecodedSHA256.rawBytes
            )
            entry.encoding = Harc_V1_LosslessEncodingConfigurationV1(
                descriptor.encoding
            )
            return entry
        }
        let batch = try HarcAudioBatchV1.create(
            header: header,
            encodedChunks: encoded
        )
        guard batch.exactBytes.count <= Self.targetExactBytes else {
            throw HarcMobileBackgroundBatchError.batchTooLarge
        }
        let descriptor = try ImmutableAudioBatchDescriptor(
            batchID: batchID,
            uploadID: plan.uploadID,
            generation: generation,
            uploadProfileSHA256: plan.frozenProfile.profileSHA256,
            originRecordingID: plan.originRecordingID,
            ownerDeviceID: plan.originRecordingID.deviceID,
            chunks: chunks.map(\.descriptor),
            exactBodyByteLength: UInt64(batch.exactBytes.count),
            exactBodySHA256: try ImmutableBatchSHA256(batch.exactSHA256)
        )
        let destination = directory.appendingPathComponent(
            "\(batchID.description).harcab1"
        )
        try HarcMobileTransferArtifactPublisher.publishImmutable(
            batch.exactBytes,
            to: destination,
            attributes: attributes
        )
        return try HarcPreparedBackgroundAudioBatchV1(
            descriptor: descriptor,
            bodyFileURL: destination
        )
    }

    private static func batchID(
        uploadID: UploadID,
        generation: UploadGeneration,
        chunks: [LogicalChunkDescriptor]
    ) -> AudioBatchID {
        var input = Data("harc-mobile-background-batch-id-v1".utf8)
        input.append(uuidBytes(uploadID.rawValue))
        var generationBytes = generation.rawValue.bigEndian
        withUnsafeBytes(of: &generationBytes) {
            input.append(contentsOf: $0)
        }
        for chunk in chunks {
            input.append(uuidBytes(chunk.chunkID.rawValue))
            var index = chunk.chunkIndex.bigEndian
            withUnsafeBytes(of: &index) { input.append(contentsOf: $0) }
            input.append(chunk.encodedSHA256.rawBytes)
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return AudioBatchID(uuid)
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }
}
