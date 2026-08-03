import CryptoKit
import Darwin
import Foundation
import HarcTransfer

/// An explicitly owned, read-only descriptor for one durable staging object.
///
/// The descriptor is opened relative to HarcHost's lifetime-retained
/// `stagingRoot/objects` directory descriptor. It is never reconstructed from
/// an absolute path. The handle owns the descriptor until `close()` or
/// deinitialization; consumers may read it sequentially but must not retain a
/// raw descriptor outside this value.
public final class HostStagedObjectReadHandle: @unchecked Sendable {
    public static let maximumReadBytes = 1_024 * 1_024

    private let directory: HostStagingDirectory
    private let objectName: String
    private let stateLock = NSLock()
    private var fileDescriptor: Int32

    init(directory: HostStagingDirectory, objectName: String) throws {
        self.directory = directory
        self.objectName = objectName
        fileDescriptor = try directory.openExistingObject(
            named: objectName,
            writable: false
        )
    }

    deinit { close() }

    /// Reads at most `maximumCount` bytes from the handle's current position.
    /// An empty result is EOF. The open inode and its generated directory entry
    /// are revalidated around every read so ancestor replacement, entry swaps,
    /// and hard-link attacks fail closed.
    public func read(upToCount maximumCount: Int) throws -> Data {
        guard maximumCount > 0 else {
            throw HarcHostError.publicationIO(
                "A staged descriptor read must request at least one byte."
            )
        }
        guard maximumCount <= Self.maximumReadBytes else {
            throw HarcHostError.bodyFragmentTooLarge(
                limit: Self.maximumReadBytes,
                actual: maximumCount
            )
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard fileDescriptor >= 0 else { throw HarcHostError.unsafeStagingPath }
        try directory.validateOpenObject(fileDescriptor, named: objectName)

        var bytes = Data(count: maximumCount)
        let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            while true {
                let result = Darwin.read(fileDescriptor, baseAddress, maximumCount)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard count >= 0 else { throw Self.io("read staged object") }
        bytes.removeSubrange(count ..< bytes.count)
        try directory.validateOpenObject(fileDescriptor, named: objectName)
        return bytes
    }

    /// Verifies the exact encoded length and hash from this handle's current
    /// zero position. Verification handles are never reused for decoding.
    func verifyEncodedObject(
        matches logicalDescriptor: LogicalChunkDescriptor,
        maximumFragmentBytes: Int
    ) throws {
        guard maximumFragmentBytes > 0 else {
            throw HarcHostError.publicationIO(
                "The staged verification fragment bound must be positive."
            )
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard fileDescriptor >= 0 else { throw HarcHostError.unsafeStagingPath }
        try directory.validateOpenObject(fileDescriptor, named: objectName)

        var information = stat()
        guard fstat(fileDescriptor, &information) == 0,
              information.st_size >= 0
        else { throw Self.io("inspect staged object") }
        guard UInt64(information.st_size) == logicalDescriptor.encodedByteLength else {
            throw HarcHostError.encodedLengthMismatch(
                expected: logicalDescriptor.encodedByteLength,
                actual: information.st_size >= 0 ? UInt64(information.st_size) : 0
            )
        }
        guard lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
            throw Self.io("position staged object at its beginning")
        }

        var hasher = SHA256()
        var length: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: maximumFragmentBytes)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.io("rehash staged object")
            }
            if count == 0 { break }
            let next = length.addingReportingOverflow(UInt64(count))
            guard !next.overflow,
                  next.partialValue <= logicalDescriptor.encodedByteLength
            else {
                throw HarcHostError.encodedLengthMismatch(
                    expected: logicalDescriptor.encodedByteLength,
                    actual: next.partialValue
                )
            }
            hasher.update(data: Data(buffer[0 ..< count]))
            length = next.partialValue
        }
        guard length == logicalDescriptor.encodedByteLength else {
            throw HarcHostError.encodedLengthMismatch(
                expected: logicalDescriptor.encodedByteLength,
                actual: length
            )
        }
        guard Data(hasher.finalize()) == logicalDescriptor.encodedSHA256.rawBytes else {
            throw HarcHostError.encodedHashMismatch
        }
        try directory.validateOpenObject(fileDescriptor, named: objectName)
    }

    /// Idempotently relinquishes ownership. HarcCanonicalIngestService calls
    /// this deterministically after each hash/decode phase; deinit is backup.
    public func close() {
        stateLock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = -1
        stateLock.unlock()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    private static func io(_ operation: String) -> HarcHostError {
        .stagingIO("Could not \(operation): errno \(errno).")
    }
}

extension HarcHostStore {
    nonisolated func openDurableStagedObject(
        _ staged: HostDurableStagedChunk
    ) throws -> HostStagedObjectReadHandle {
        let name = try HostStagingDirectory.objectName(
            forGeneratedRelativePath: staged.relativePath
        )
        return try HostStagedObjectReadHandle(
            directory: stagingDirectory,
            objectName: name
        )
    }
}
