import CryptoKit
import Foundation
import HarcDomain
import HarcProtocolWire
import HarcTransfer
#if canImport(Darwin)
import Darwin
#endif

/// One bounded, hash-validated chunk read from an immutable HARCAB1 file.
public struct HarcAudioBatchFileChunkV1: Sendable {
    public let descriptor: LogicalChunkDescriptor
    public let encodedBytes: Data
}

/// Result of a streaming HARCAB1 file scan. The exact body itself is never
/// materialized as one Data value.
public struct HarcAudioBatchFileScanV1: Sendable {
    public let exactHeaderPayload: Data
    public let header: Harc_V1_AudioBatchHeaderV1
    public let descriptor: ImmutableAudioBatchDescriptor
}

public enum HarcAudioBatchFileError: Error, Equatable, Sendable {
    case notRegularFile
    case fileIdentityChanged
}

/// Bounded file-backed HARCAB1 decoder for the narrow background PUT path.
///
/// Each callback receives at most four MiB. Callers that persist during the
/// callback must use a rollback-capable temporary namespace and publish it only
/// after this method returns, because the whole-body capability hash is proven
/// at the end of the scan.
public enum HarcAudioBatchFileV1 {
    public static func scan(
        at fileURL: URL,
        expectedGeneration: UploadGeneration,
        expectedExactBodyByteLength: UInt64,
        expectedExactBodySHA256: ImmutableBatchSHA256,
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1,
        consume: (HarcAudioBatchFileChunkV1) throws -> Void
    ) throws -> HarcAudioBatchFileScanV1 {
        guard fileURL.isFileURL else {
            throw HarcProtocolCodecError.invalidEndpoint(field: "audioBatch.fileURL")
        }
        guard expectedExactBodyByteLength > 0,
              expectedExactBodyByteLength <= UInt64(HarcAudioBatchV1.maximumExactBytes) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.exactBytes",
                minimum: 1,
                maximum: UInt64(HarcAudioBatchV1.maximumExactBytes),
                actual: expectedExactBodyByteLength
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let initialIdentity = try fileIdentity(handle)
        guard initialIdentity.isRegularFile else {
            throw HarcAudioBatchFileError.notRegularFile
        }
        guard initialIdentity.byteCount == expectedExactBodyByteLength else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "audioBatch.exactBytes",
                expected: expectedExactBodyByteLength,
                actual: initialIdentity.byteCount
            )
        }
        try handle.seek(toOffset: 0)

        var hasher = SHA256()
        let magic = try readExactly(
            HarcAudioBatchV1.magic.count,
            from: handle,
            field: "HarcAudioBatchV1.magic",
            hasher: &hasher
        )
        guard magic == HarcAudioBatchV1.magic else {
            throw HarcProtocolCodecError.invalidMagic(field: "HarcAudioBatchV1")
        }
        let headerLengthBytes = try readExactly(
            4,
            from: handle,
            field: "audioBatch.headerLength",
            hasher: &hasher
        )
        let headerLength = UInt64(decodeUInt32(headerLengthBytes))
        guard headerLength > 0,
              headerLength <= UInt64(HarcAudioBatchV1.maximumHeaderBytes) else {
            throw HarcProtocolCodecError.lengthOutOfRange(
                field: "audioBatch.headerLength",
                minimum: 1,
                maximum: UInt64(HarcAudioBatchV1.maximumHeaderBytes),
                actual: headerLength
            )
        }
        guard let exactHeaderLength = Int(exactly: headerLength) else {
            throw HarcProtocolCodecError.numericOverflow(field: "audioBatch.headerLength")
        }
        let exactHeaderPayload = try readExactly(
            exactHeaderLength,
            from: handle,
            field: "audioBatch.headerPayload",
            hasher: &hasher
        )
        try HarcProtobufWirePreflight.requireRepeatedMessageCount(
            in: exactHeaderPayload,
            fieldNumber: 7,
            maximum: HarcAudioBatchV1.maximumEntries,
            field: "audioBatch.entries"
        )
        let header: Harc_V1_AudioBatchHeaderV1
        do {
            header = try Harc_V1_AudioBatchHeaderV1(serializedBytes: exactHeaderPayload)
        } catch {
            throw HarcProtobufConversionError.malformedProtobuf
        }
        try HarcAudioBatchV1.validateHeader(
            header,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        let declaredByteCount = try HarcAudioBatchV1.declaredExactByteCount(
            headerLength: headerLength,
            entries: header.entries
        )
        guard declaredByteCount == expectedExactBodyByteLength else {
            throw HarcProtocolCodecError.lengthMismatch(
                field: "audioBatch.declaredExactBytes",
                expected: expectedExactBodyByteLength,
                actual: declaredByteCount
            )
        }

        let logicalChunks = try logicalChunkDescriptors(from: header)
        for (index, entry) in header.entries.enumerated() {
            let framedLengthBytes = try readExactly(
                4,
                from: handle,
                field: "audioBatch.entries[\(index)].length",
                hasher: &hasher
            )
            let framedLength = UInt64(decodeUInt32(framedLengthBytes))
            let declaredLength = UInt64(entry.encodedLength)
            guard framedLength == declaredLength else {
                throw HarcProtocolCodecError.lengthMismatch(
                    field: "audioBatch.entries[\(index)].encodedLength",
                    expected: declaredLength,
                    actual: framedLength
                )
            }
            guard framedLength > 0,
                  framedLength <= UInt64(HarcAudioBatchV1.maximumEntryBytes),
                  let chunkLength = Int(exactly: framedLength) else {
                throw HarcProtocolCodecError.lengthOutOfRange(
                    field: "audioBatch.entries[\(index)].encodedLength",
                    minimum: 1,
                    maximum: UInt64(HarcAudioBatchV1.maximumEntryBytes),
                    actual: framedLength
                )
            }
            let encodedBytes = try readExactly(
                chunkLength,
                from: handle,
                field: "audioBatch.entries[\(index)].payload",
                hasher: &hasher
            )
            guard Data(SHA256.hash(data: encodedBytes)) == entry.encodedSha256.value else {
                throw HarcProtocolCodecError.payloadHashMismatch
            }
            try consume(HarcAudioBatchFileChunkV1(
                descriptor: logicalChunks[index],
                encodedBytes: encodedBytes
            ))
        }

        let trailing = try handle.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
            throw HarcProtocolCodecError.trailingBytes(count: trailing.count)
        }
        let finalIdentity = try fileIdentity(handle)
        guard finalIdentity == initialIdentity else {
            throw HarcAudioBatchFileError.fileIdentityChanged
        }
        let exactDigest = Data(hasher.finalize())
        guard exactDigest == expectedExactBodySHA256.rawBytes else {
            throw HarcProtocolCodecError.payloadHashMismatch
        }

        let descriptor = try ImmutableAudioBatchDescriptor(
            batchID: try header.batchID.domainValue(),
            uploadID: try header.uploadID.domainValue(),
            generation: expectedGeneration,
            uploadProfileSHA256: try UploadProfileSHA256(
                header.uploadProfileSha256.validatedBytes(
                    field: "audioBatch.uploadProfileSHA256"
                )
            ),
            originRecordingID: try header.originRecordingID.domainValue(),
            ownerDeviceID: try header.deviceID.domainValue(),
            chunks: logicalChunks,
            exactBodyByteLength: expectedExactBodyByteLength,
            exactBodySHA256: expectedExactBodySHA256
        )
        return HarcAudioBatchFileScanV1(
            exactHeaderPayload: exactHeaderPayload,
            header: header,
            descriptor: descriptor
        )
    }

    private static func logicalChunkDescriptors(
        from header: Harc_V1_AudioBatchHeaderV1
    ) throws -> [LogicalChunkDescriptor] {
        let origin = try header.originRecordingID.domainValue()
        return try header.entries.enumerated().map { index, entry in
            let decodedByteCount = entry.canonicalFrameCount.multipliedReportingOverflow(by: 2)
            guard !decodedByteCount.overflow else {
                throw HarcProtocolCodecError.numericOverflow(
                    field: "audioBatch.entries[\(index)].canonicalDecodedBytes"
                )
            }
            return try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: try entry.chunkID.domainValue(),
                chunkIndex: entry.chunkIndex,
                canonicalStartFrame: entry.canonicalStartFrame,
                canonicalFrameCount: entry.canonicalFrameCount,
                encoding: try entry.encoding.domainValue(),
                encodedByteLength: UInt64(entry.encodedLength),
                encodedSHA256: try EncodedChunkSHA256(
                    entry.encodedSha256.validatedBytes(
                        field: "audioBatch.entries[\(index)].encodedSHA256"
                    )
                ),
                canonicalDecodedByteLength: decodedByteCount.partialValue,
                canonicalDecodedSHA256: try CanonicalPCMHash(
                    entry.canonicalDecodedSha256.validatedBytes(
                        field: "audioBatch.entries[\(index)].canonicalDecodedSHA256"
                    )
                )
            )
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let isRegularFile: Bool
    }

    private static func fileIdentity(_ handle: FileHandle) throws -> FileIdentity {
        #if canImport(Darwin)
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        guard status.st_size >= 0 else {
            throw HarcProtocolCodecError.numericOverflow(field: "audioBatch.fileSize")
        }
        return FileIdentity(
            device: UInt64(UInt32(bitPattern: status.st_dev)),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            isRegularFile: (status.st_mode & S_IFMT) == S_IFREG
        )
        #else
        let offset = try handle.offset()
        let byteCount = try handle.seekToEnd()
        try handle.seek(toOffset: offset)
        return FileIdentity(
            device: 0,
            inode: 0,
            byteCount: byteCount,
            modifiedSeconds: 0,
            modifiedNanoseconds: 0,
            isRegularFile: true
        )
        #endif
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        field: String,
        hasher: inout SHA256
    ) throws -> Data {
        guard count >= 0 else {
            throw HarcProtocolCodecError.numericOverflow(field: field)
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            guard let part = try handle.read(upToCount: remaining), !part.isEmpty else {
                throw HarcProtocolCodecError.truncated(field: field)
            }
            result.append(part)
        }
        hasher.update(data: result)
        return result
    }

    private static func decodeUInt32(_ bytes: Data) -> UInt32 {
        bytes.reduce(into: UInt32(0)) { value, byte in
            value = (value << 8) | UInt32(byte)
        }
    }
}
