import CryptoKit
import Darwin
import Foundation
import HarcDomain

public struct HarcHostAudioDownloadDescriptor: Equatable, Sendable {
    public let canonicalID: CanonicalRecordingID
    public let revision: EntityRevision
    public let contentType: String
    public let totalByteLength: UInt64
    public let contentSHA256: Data
    public let canonicalFormat: CanonicalPCMFormat
    public let totalCanonicalFrames: UInt64
    public let canonicalPCMSHA256: CanonicalPCMHash
}

public struct HarcHostPreparedAudioDownload: Sendable {
    public let descriptor: HarcHostAudioDownloadDescriptor
    public let reader: HarcHostCanonicalAudioReader
}

/// A retained, identity-checked descriptor for one canonical WAV download.
/// The complete representation and PCM hashes are verified before the caller
/// can emit its descriptor. Every bounded `pread` revalidates the open file and
/// pathname binding before and after I/O, so replacement or in-place mutation
/// fails the stream instead of serving mixed bytes.
public actor HarcHostCanonicalAudioReader {
    public static let maximumFrameBytes = 4 * 1_024 * 1_024

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let owner: UInt32
        let mode: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ value: stat) throws {
            guard value.st_size >= 0 else {
                throw HarcHostLibraryError.canonicalAudioChanged
            }
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            byteCount = UInt64(value.st_size)
            owner = value.st_uid
            mode = value.st_mode
            modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = Int64(value.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    public nonisolated let descriptor: HarcHostAudioDownloadDescriptor

    private let fileDescriptor: Int32
    private let path: String
    private let identity: FileIdentity

    init(
        canonicalID: CanonicalRecordingID,
        revision: EntityRevision,
        fileURL: URL,
        canonicalPCMSHA256: CanonicalPCMHash,
        totalCanonicalFrames: UInt64
    ) throws {
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              !fileURL.path.contains("\0"),
              fileURL.standardizedFileURL.path == fileURL.path else {
            throw HarcHostLibraryError.canonicalAudioUnavailable
        }
        path = fileURL.path
        let opened = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard opened >= 0 else {
            throw HarcHostLibraryError.canonicalAudioUnavailable
        }
        fileDescriptor = opened
        do {
            var information = stat()
            guard fstat(opened, &information) == 0,
                  (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == geteuid() else {
                throw HarcHostLibraryError.canonicalAudioUnavailable
            }
            identity = try FileIdentity(information)
            let layout = try HostCanonicalWAVLayout(
                totalFrames: totalCanonicalFrames
            )
            guard identity.byteCount == layout.fileByteCount else {
                throw HarcHostLibraryError.canonicalAudioChanged
            }
            let verified = try Self.hashAndValidate(
                descriptor: opened,
                layout: layout,
                expectedPCMHash: canonicalPCMSHA256
            )
            try Self.validateBinding(
                descriptor: opened,
                path: path,
                expected: identity
            )
            descriptor = HarcHostAudioDownloadDescriptor(
                canonicalID: canonicalID,
                revision: revision,
                contentType: "audio/wav",
                totalByteLength: layout.fileByteCount,
                contentSHA256: verified.representationHash,
                canonicalFormat: .harcV1,
                totalCanonicalFrames: totalCanonicalFrames,
                canonicalPCMSHA256: canonicalPCMSHA256
            )
        } catch {
            _ = Darwin.close(opened)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    public func read(
        at byteOffset: UInt64,
        maximumBytes: Int
    ) throws -> Data? {
        guard (1 ... Self.maximumFrameBytes).contains(maximumBytes),
              byteOffset <= descriptor.totalByteLength else {
            throw HarcHostLibraryError.invalidResumeOffset
        }
        try Self.validateBinding(
            descriptor: fileDescriptor,
            path: path,
            expected: identity
        )
        guard byteOffset < descriptor.totalByteLength else { return nil }
        let remaining = descriptor.totalByteLength - byteOffset
        let count = min(maximumBytes, Int(remaining))
        let data = try Self.readExactly(
            count: count,
            at: byteOffset,
            from: fileDescriptor
        )
        try Self.validateBinding(
            descriptor: fileDescriptor,
            path: path,
            expected: identity
        )
        return data
    }

    private static func hashAndValidate(
        descriptor: Int32,
        layout: HostCanonicalWAVLayout,
        expectedPCMHash: CanonicalPCMHash
    ) throws -> (representationHash: Data, pcmHash: Data) {
        let header = try readExactly(
            count: Int(HostCanonicalWAVLayout.headerByteCount),
            at: 0,
            from: descriptor
        )
        guard header == layout.header else {
            throw HarcHostLibraryError.canonicalAudioChanged
        }
        var representationHasher = SHA256()
        var pcmHasher = SHA256()
        representationHasher.update(data: header)
        var offset = HostCanonicalWAVLayout.headerByteCount
        while offset < layout.fileByteCount {
            let remaining = layout.fileByteCount - offset
            let count = min(1 * 1_024 * 1_024, Int(remaining))
            let bytes = try readExactly(
                count: count,
                at: offset,
                from: descriptor
            )
            representationHasher.update(data: bytes)
            pcmHasher.update(data: bytes)
            offset += UInt64(bytes.count)
        }
        let pcmHash = Data(pcmHasher.finalize())
        guard pcmHash == expectedPCMHash.rawBytes else {
            throw HarcHostLibraryError.canonicalAudioChanged
        }
        return (Data(representationHasher.finalize()), pcmHash)
    }

    private static func validateBinding(
        descriptor: Int32,
        path: String,
        expected: FileIdentity
    ) throws {
        var openInformation = stat()
        var pathInformation = stat()
        guard fstat(descriptor, &openInformation) == 0,
              lstat(path, &pathInformation) == 0,
              (pathInformation.st_mode & S_IFMT) == S_IFREG,
              try FileIdentity(openInformation) == expected,
              try FileIdentity(pathInformation) == expected else {
            throw HarcHostLibraryError.canonicalAudioChanged
        }
    }

    private static func readExactly(
        count: Int,
        at offset: UInt64,
        from descriptor: Int32
    ) throws -> Data {
        guard count >= 0,
              let start = off_t(exactly: offset) else {
            throw HarcHostLibraryError.canonicalAudioChanged
        }
        var data = Data(count: count)
        var consumed = 0
        try data.withUnsafeMutableBytes { raw in
            while consumed < count {
                let result = pread(
                    descriptor,
                    raw.baseAddress!.advanced(by: consumed),
                    count - consumed,
                    start + off_t(consumed)
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw HarcHostLibraryError.canonicalAudioChanged
                }
                consumed += result
            }
        }
        return data
    }
}
