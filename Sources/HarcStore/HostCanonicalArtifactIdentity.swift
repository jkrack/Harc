import Darwin
import Foundation

/// Portable, persistable identity for one already-validated canonical WAV.
///
/// HarcHost captures this value from its retained read-only descriptor after
/// hashing the WAV. HarcStore then proves that the normalized pathname still
/// names that exact current-user-owned inode inside the canonical transaction.
/// Change time closes the same-UID, same-inode, same-size in-place-write gap.
public struct HostCanonicalArtifactIdentity: Codable, Equatable, Sendable {
    public let deviceNumber: UInt64
    public let inodeNumber: UInt64
    public let ownerUserID: UInt32
    public let posixMode: UInt32
    public let linkCount: UInt64
    public let fileByteCount: UInt64
    public let changeTimeSeconds: Int64
    public let changeTimeNanoseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case deviceNumber
        case inodeNumber
        case ownerUserID
        case posixMode
        case linkCount
        case fileByteCount
        case changeTimeSeconds
        case changeTimeNanoseconds
    }

    public init(
        deviceNumber: UInt64,
        inodeNumber: UInt64,
        ownerUserID: UInt32,
        posixMode: UInt32,
        linkCount: UInt64,
        fileByteCount: UInt64,
        changeTimeSeconds: Int64,
        changeTimeNanoseconds: Int64
    ) throws {
        guard (posixMode & UInt32(S_IFMT)) == UInt32(S_IFREG),
              (posixMode & 0o022) == 0,
              linkCount == 1,
              fileByteCount > 0,
              (0 ..< 1_000_000_000).contains(changeTimeNanoseconds)
        else {
            throw StoreError.invalidData(
                "Canonical artifact identity must describe one private regular file"
            )
        }
        self.deviceNumber = deviceNumber
        self.inodeNumber = inodeNumber
        self.ownerUserID = ownerUserID
        self.posixMode = posixMode
        self.linkCount = linkCount
        self.fileByteCount = fileByteCount
        self.changeTimeSeconds = changeTimeSeconds
        self.changeTimeNanoseconds = changeTimeNanoseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceNumber: container.decode(UInt64.self, forKey: .deviceNumber),
                inodeNumber: container.decode(UInt64.self, forKey: .inodeNumber),
                ownerUserID: container.decode(UInt32.self, forKey: .ownerUserID),
                posixMode: container.decode(UInt32.self, forKey: .posixMode),
                linkCount: container.decode(UInt64.self, forKey: .linkCount),
                fileByteCount: container.decode(UInt64.self, forKey: .fileByteCount),
                changeTimeSeconds: container.decode(Int64.self, forKey: .changeTimeSeconds),
                changeTimeNanoseconds: container.decode(
                    Int64.self,
                    forKey: .changeTimeNanoseconds
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid canonical artifact identity",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceNumber, forKey: .deviceNumber)
        try container.encode(inodeNumber, forKey: .inodeNumber)
        try container.encode(ownerUserID, forKey: .ownerUserID)
        try container.encode(posixMode, forKey: .posixMode)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(fileByteCount, forKey: .fileByteCount)
        try container.encode(changeTimeSeconds, forKey: .changeTimeSeconds)
        try container.encode(changeTimeNanoseconds, forKey: .changeTimeNanoseconds)
    }

    /// Captures identity from a retained descriptor and proves that `url`
    /// names that descriptor's exact inode without following a leaf symlink.
    public init(
        validatingOpenFileDescriptor fileDescriptor: Int32,
        boundTo url: URL
    ) throws {
        let snapshot = try Self.snapshot(ofOpenFileDescriptor: fileDescriptor)
        try Self.requireSafeArtifact(snapshot)
        self = try Self(
            deviceNumber: snapshot.deviceNumber,
            inodeNumber: snapshot.inodeNumber,
            ownerUserID: snapshot.ownerUserID,
            posixMode: snapshot.posixMode,
            linkCount: snapshot.linkCount,
            fileByteCount: snapshot.fileByteCount,
            changeTimeSeconds: snapshot.changeTimeSeconds,
            changeTimeNanoseconds: snapshot.changeTimeNanoseconds
        )
        try validate(openFileDescriptor: fileDescriptor, boundTo: url)
    }

    /// Revalidates both the retained descriptor and its current pathname entry.
    /// The caller retains ownership of `fileDescriptor` for the whole call.
    public func validate(
        openFileDescriptor fileDescriptor: Int32,
        boundTo url: URL
    ) throws {
        let opened = try Self.snapshot(ofOpenFileDescriptor: fileDescriptor)
        try Self.requireSafeArtifact(opened)
        guard matches(opened) else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        try validatePathBinding(at: url)
    }

    /// Revalidates the normalized URL's leaf entry against this exact identity.
    /// `lstat` is intentional: a symlink is never accepted as a WAV binding.
    public func validatePathBinding(at url: URL) throws {
        try Self.requireNormalizedAbsoluteFileURL(url)
        let named = try Self.snapshot(atPath: url.path)
        try Self.requireSafeArtifact(named)
        guard matches(named) else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
    }

    private struct Snapshot {
        let deviceNumber: UInt64
        let inodeNumber: UInt64
        let ownerUserID: UInt32
        let posixMode: UInt32
        let linkCount: UInt64
        let fileByteCount: UInt64
        let changeTimeSeconds: Int64
        let changeTimeNanoseconds: Int64
    }

    private func matches(_ snapshot: Snapshot) -> Bool {
        deviceNumber == snapshot.deviceNumber
            && inodeNumber == snapshot.inodeNumber
            && ownerUserID == snapshot.ownerUserID
            && posixMode == snapshot.posixMode
            && linkCount == snapshot.linkCount
            && fileByteCount == snapshot.fileByteCount
            && changeTimeSeconds == snapshot.changeTimeSeconds
            && changeTimeNanoseconds == snapshot.changeTimeNanoseconds
    }

    private static func snapshot(ofOpenFileDescriptor descriptor: Int32) throws -> Snapshot {
        guard descriptor >= 0 else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        return try snapshot(information)
    }

    private static func snapshot(atPath path: String) throws -> Snapshot {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            throw StoreError.canonicalArtifactIdentityMismatch
        }
        return try snapshot(information)
    }

    private static func snapshot(_ information: stat) throws -> Snapshot {
        guard let deviceNumber = UInt64(exactly: information.st_dev),
              let inodeNumber = UInt64(exactly: information.st_ino),
              let ownerUserID = UInt32(exactly: information.st_uid),
              let posixMode = UInt32(exactly: information.st_mode),
              let linkCount = UInt64(exactly: information.st_nlink),
              information.st_size >= 0,
              let changeTimeSeconds = Int64(exactly: information.st_ctimespec.tv_sec),
              let changeTimeNanoseconds = Int64(exactly: information.st_ctimespec.tv_nsec)
        else { throw StoreError.canonicalArtifactIdentityMismatch }
        return Snapshot(
            deviceNumber: deviceNumber,
            inodeNumber: inodeNumber,
            ownerUserID: ownerUserID,
            posixMode: posixMode,
            linkCount: linkCount,
            fileByteCount: UInt64(information.st_size),
            changeTimeSeconds: changeTimeSeconds,
            changeTimeNanoseconds: changeTimeNanoseconds
        )
    }

    private static func requireSafeArtifact(_ snapshot: Snapshot) throws {
        guard (snapshot.posixMode & UInt32(S_IFMT)) == UInt32(S_IFREG),
              snapshot.ownerUserID == UInt32(geteuid()),
              (snapshot.posixMode & 0o022) == 0,
              snapshot.linkCount == 1,
              snapshot.fileByteCount > 0,
              (0 ..< 1_000_000_000).contains(snapshot.changeTimeNanoseconds)
        else { throw StoreError.canonicalArtifactIdentityMismatch }
    }

    private static func requireNormalizedAbsoluteFileURL(_ url: URL) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("\0"),
              url.standardizedFileURL.path == url.path
        else {
            throw StoreError.invalidData("Canonical WAV path must be absolute and normalized")
        }
    }
}
