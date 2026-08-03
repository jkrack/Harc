import CryptoKit
import Darwin
import Foundation
import HarcDomain
import HarcStore

struct HostCanonicalWAVLayout: Equatable, Sendable {
    static let headerByteCount: UInt64 = 44
    static let maximumPCMByteCount = UInt64(UInt32.max) - 36

    let totalFrames: UInt64
    let pcmByteCount: UInt64
    let fileByteCount: UInt64
    let header: Data

    init(totalFrames: UInt64) throws {
        guard totalFrames > 0 else {
            throw HarcHostError.invalidCanonicalFrameCount(totalFrames)
        }
        let multiplied = totalFrames.multipliedReportingOverflow(by: 2)
        guard !multiplied.overflow,
              multiplied.partialValue <= Self.maximumPCMByteCount
        else {
            throw HarcHostError.classicRIFFSizeExceeded(
                maximumPCMBytes: Self.maximumPCMByteCount,
                requestedPCMBytes: multiplied.partialValue
            )
        }
        pcmByteCount = multiplied.partialValue
        fileByteCount = Self.headerByteCount + pcmByteCount
        self.totalFrames = totalFrames
        header = Self.makeHeader(pcmByteCount: UInt32(pcmByteCount))
    }

    private static func makeHeader(pcmByteCount: UInt32) -> Data {
        var bytes = Data()
        bytes.reserveCapacity(Int(headerByteCount))
        bytes.append(Data("RIFF".utf8))
        bytes.appendLittleEndian(UInt32(36) + pcmByteCount)
        bytes.append(Data("WAVE".utf8))
        bytes.append(Data("fmt ".utf8))
        bytes.appendLittleEndian(UInt32(16))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt32(16_000))
        bytes.appendLittleEndian(UInt32(32_000))
        bytes.appendLittleEndian(UInt16(2))
        bytes.appendLittleEndian(UInt16(16))
        bytes.append(Data("data".utf8))
        bytes.appendLittleEndian(pcmByteCount)
        precondition(bytes.count == Int(headerByteCount))
        return bytes
    }
}

/// Retains the exact descriptor opened through a trusted canonical directory.
/// Every content validation brackets the complete header/PCM read with the
/// same persisted identity, so in-place mutation, leaf replacement, and root
/// replacement all fail closed.
final class HostValidatedCanonicalArtifact: @unchecked Sendable {
    let identity: HostCanonicalArtifactIdentity
    let url: URL

    private let descriptor: Int32
    private let paths: HostCanonicalPublicationPaths
    private let layout: HostCanonicalWAVLayout
    private let expectedPCMHash: CanonicalPCMHash

    init(
        at url: URL,
        in paths: HostCanonicalPublicationPaths,
        totalFrames: UInt64,
        expectedPCMHash: CanonicalPCMHash,
        expectedIdentity: HostCanonicalArtifactIdentity? = nil
    ) throws {
        self.url = url
        self.paths = paths
        layout = try HostCanonicalWAVLayout(totalFrames: totalFrames)
        self.expectedPCMHash = expectedPCMHash
        descriptor = try paths.openExistingRegularFile(at: url)
        do {
            let captured = try HostCanonicalArtifactIdentity(
                validatingOpenFileDescriptor: descriptor,
                boundTo: url
            )
            if let expectedIdentity {
                guard captured == expectedIdentity else {
                    throw HarcHostError.canonicalArtifactIdentityMismatch
                }
                identity = expectedIdentity
            } else {
                identity = captured
            }
            guard identity.fileByteCount == layout.fileByteCount else {
                throw HarcHostError.unsafePublicationPath
            }
            try validateCanonicalContent()
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    /// Cheap interstitial proof used around actor hops and sidecar operations.
    /// Ctime catches same-inode writes; the retained root/path checks catch
    /// ancestor or leaf replacement without rereading multi-gigabyte PCM.
    func validateBinding() throws {
        try identity.validate(openFileDescriptor: descriptor, boundTo: url)
        try paths.validateOpenFile(descriptor, at: url)
    }

    func validateCanonicalContent() throws {
        try validateBinding()
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw HarcHostError.publicationIO(
                "Could not rewind the canonical WAV: errno \(errno)."
            )
        }

        let header = try HostCanonicalWAVAssembler.readExactly(
            Int(HostCanonicalWAVLayout.headerByteCount),
            from: descriptor
        )
        guard header == layout.header else { throw HarcHostError.invalidCanonicalWAV }

        var hasher = SHA256()
        var remaining = layout.pcmByteCount
        while remaining > 0 {
            let requested = Int(min(remaining, UInt64(256 * 1_024)))
            let fragment = try HostCanonicalWAVAssembler.readExactly(
                requested,
                from: descriptor
            )
            hasher.update(data: fragment)
            remaining -= UInt64(fragment.count)
        }
        let actual = try CanonicalPCMHash(Data(hasher.finalize()))
        guard actual == expectedPCMHash else { throw HarcHostError.canonicalHashMismatch }

        // This post-read identity check is part of the hash proof. Capturing
        // identity only after the read could bless bytes mutated behind the
        // reader after their region had already been hashed.
        try validateBinding()
    }
}

/// Incremental, allocation-bounded classic RIFF/WAVE writer. The final PCM
/// size is known from the authenticated manifest, so the complete canonical
/// header is written before any decoded byte becomes durable.
final class HostCanonicalWAVAssembler: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let paths: HostCanonicalPublicationPaths
    private let temporaryURL: URL
    private let layout: HostCanonicalWAVLayout
    private var hasher = SHA256()
    private var pcmBytesWritten: UInt64 = 0
    private var closed = false

    init(paths: HostCanonicalPublicationPaths, totalFrames: UInt64) throws {
        self.paths = paths
        temporaryURL = paths.temporaryURL
        layout = try HostCanonicalWAVLayout(totalFrames: totalFrames)
        fileDescriptor = try paths.createExclusiveFile(at: temporaryURL)
        do {
            try Self.writeAll(layout.header, to: fileDescriptor)
        } catch {
            try? paths.removeFile(at: temporaryURL, matching: fileDescriptor)
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    deinit {
        if !closed { Darwin.close(fileDescriptor) }
    }

    func appendCanonicalPCM(_ bytes: Data) throws {
        guard !closed else {
            throw HarcHostError.publicationIO("The canonical WAV writer is closed.")
        }
        guard !bytes.isEmpty else { return }
        let added = pcmBytesWritten.addingReportingOverflow(UInt64(bytes.count))
        guard !added.overflow, added.partialValue <= layout.pcmByteCount else {
            throw HarcHostError.decodedLengthMismatch(
                expected: layout.pcmByteCount,
                actual: added.partialValue
            )
        }
        try Self.writeAll(bytes, to: fileDescriptor)
        hasher.update(data: bytes)
        pcmBytesWritten = added.partialValue
    }

    @discardableResult
    func synchronizeAndClose(expectedPCMHash: CanonicalPCMHash) throws -> CanonicalPCMHash {
        guard !closed else {
            throw HarcHostError.publicationIO("The canonical WAV writer is already closed.")
        }
        guard pcmBytesWritten == layout.pcmByteCount else {
            throw HarcHostError.decodedLengthMismatch(
                expected: layout.pcmByteCount,
                actual: pcmBytesWritten
            )
        }
        let actualHash = try CanonicalPCMHash(Data(hasher.finalize()))
        guard actualHash == expectedPCMHash else {
            throw HarcHostError.canonicalHashMismatch
        }
        guard fsync(fileDescriptor) == 0 else {
            throw HarcHostError.publicationIO(
                "Could not synchronize the canonical WAV: errno \(errno)."
            )
        }
        try paths.validateOpenFile(fileDescriptor, at: temporaryURL)
        let closeResult = Darwin.close(fileDescriptor)
        closed = true
        guard closeResult == 0 else {
            throw HarcHostError.publicationIO(
                "Could not close the canonical WAV: errno \(errno)."
            )
        }
        return actualHash
    }

    static func publishExclusively(in paths: HostCanonicalPublicationPaths) throws {
        try paths.renameExclusively(from: paths.temporaryURL, to: paths.wavURL)
    }

    static func validatePublishedFile(
        at url: URL,
        in paths: HostCanonicalPublicationPaths,
        totalFrames: UInt64,
        expectedPCMHash: CanonicalPCMHash,
        expectedIdentity: HostCanonicalArtifactIdentity? = nil
    ) throws -> HostCanonicalArtifactIdentity {
        try openValidatedPublishedFile(
            at: url,
            in: paths,
            totalFrames: totalFrames,
            expectedPCMHash: expectedPCMHash,
            expectedIdentity: expectedIdentity
        ).identity
    }

    static func openValidatedPublishedFile(
        at url: URL,
        in paths: HostCanonicalPublicationPaths,
        totalFrames: UInt64,
        expectedPCMHash: CanonicalPCMHash,
        expectedIdentity: HostCanonicalArtifactIdentity? = nil
    ) throws -> HostValidatedCanonicalArtifact {
        try HostValidatedCanonicalArtifact(
            at: url,
            in: paths,
            totalFrames: totalFrames,
            expectedPCMHash: expectedPCMHash,
            expectedIdentity: expectedIdentity
        )
    }

    static func writeExactSidecar(
        _ bytes: Data,
        to url: URL,
        in paths: HostCanonicalPublicationPaths
    ) throws {
        guard !bytes.isEmpty else {
            throw HarcHostError.publicationIO("A provenance sidecar cannot be empty.")
        }
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".harc-\(url.lastPathComponent).partial"
        )

        // A process death may leave only the host-generated sibling temp. It
        // was never a published sidecar and is safe to discard after proving
        // that it is still a current-user-owned regular file, not a symlink.
        if try paths.entryExists(at: temporaryURL) {
            try paths.removeOwnedRegularFileIfPresent(at: temporaryURL)
            try paths.synchronizeDirectory()
        }

        let descriptor = try paths.createExclusiveFile(at: temporaryURL)
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
        }
        do {
            try writeAll(bytes, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw HarcHostError.publicationIO(
                    "Could not synchronize a provenance sidecar temporary file: errno \(errno)."
                )
            }
            try paths.validateOpenFile(descriptor, at: temporaryURL)

            do {
                try paths.renameExclusively(from: temporaryURL, to: url)
            } catch HarcHostError.canonicalDestinationExists {
                let existing = try readExactSidecar(
                    at: url,
                    in: paths,
                    maximumBytes: 16 * 1_024 * 1_024
                )
                guard existing == bytes else {
                    throw HarcHostError.provenanceSidecarConflict
                }
                try paths.removeFile(at: temporaryURL, matching: descriptor)
            }
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw HarcHostError.publicationIO(
                    "Could not close a provenance sidecar temporary file: errno \(errno)."
                )
            }
            try paths.synchronizeDirectory()
        } catch {
            if descriptorIsOpen {
                Darwin.close(descriptor)
                descriptorIsOpen = false
            }
            // Leaving the generated temp is safe. A later replay removes it
            // through the same descriptor-relative, no-follow validation.
            throw error
        }
    }

    static func readExactSidecar(
        at url: URL,
        in paths: HostCanonicalPublicationPaths,
        maximumBytes: UInt64
    ) throws -> Data {
        let descriptor = try paths.openExistingRegularFile(at: url)
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_size > 0,
              UInt64(information.st_size) <= maximumBytes
        else { throw HarcHostError.unsafePublicationPath }
        let bytes = try readExactly(Int(information.st_size), from: descriptor)
        try paths.validateOpenFile(descriptor, at: url)
        return bytes
    }

    static func synchronizeDirectory(_ paths: HostCanonicalPublicationPaths) throws {
        try paths.synchronizeDirectory()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw HarcHostError.publicationIO(
                        "Could not write a canonical artifact: errno \(errno)."
                    )
                }
            }
        }
    }

    fileprivate static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let result = data.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                throw HarcHostError.incompleteBody
            } else {
                throw HarcHostError.publicationIO(
                    "Could not read a canonical artifact: errno \(errno)."
                )
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
