import CryptoKit
import Darwin
import Foundation

/// Local-only intent for publishing a finalized, no-longer-written master.
/// The immutable journal survives source removal and the later Library commit.
public struct RecordingPublication: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let byteCount: UInt64
    public let sha256: Data
    public let destinationVolumeIdentity: String

    public enum PublicationError: Error, LocalizedError {
        case invalidJournal, contentConflict, missingMaster, destinationUnavailable
        public var errorDescription: String? {
            switch self {
            case .invalidJournal: "Recording publication metadata is invalid. Existing files were preserved."
            case .contentConflict: "Recording publication found different file contents. Existing files were preserved."
            case .missingMaster: "Neither the cached master nor its published copy is available."
            case .destinationUnavailable: "The recording destination volume is unavailable or has changed. The cached recording was preserved."
            }
        }
    }

    public static func journalURL(for source: URL) -> URL {
        source.appendingPathExtension("publication.json")
    }

    public var stagingURL: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".harc-publication-\(id.uuidString.lowercased()).tmp")
    }

    public static func load(for source: URL) throws -> Self? {
        guard source.isFileURL, !source.path.contains("\0") else { throw PublicationError.invalidJournal }
        let url = journalURL(for: source)
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? .max) <= 65_536 else { throw PublicationError.invalidJournal }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 2, value.source == source.standardized,
              !value.destinationVolumeIdentity.isEmpty,
              value.destination.isFileURL, !value.destination.path.contains("\0"),
              value.destination == value.destination.standardized,
              value.source != value.destination, value.byteCount > 0, value.sha256.count == 32,
              value.source.pathExtension.lowercased() == "wav",
              value.destination.pathExtension.lowercased() == "wav"
        else { throw PublicationError.invalidJournal }
        return value
    }

    /// Select once, before making any destination file visible. Competing
    /// creators cannot replace an existing intent or choose a second destination.
    public static func prepare(source: URL, destination: URL, expectedVolumeIdentity: String? = nil) throws -> Self {
        // Lexical normalization is stable before and after directory creation.
        // standardizedFileURL can rewrite /private/tmp to /tmp only after the
        // destination exists, which would change the persisted Library key.
        let source = source.standardized
        let destination = destination.standardized
        guard source.isFileURL, destination.isFileURL, source != destination,
              !source.path.contains("\0"), !destination.path.contains("\0"),
              source.pathExtension.lowercased() == "wav", destination.pathExtension.lowercased() == "wav"
        else { throw PublicationError.invalidJournal }
        let captureBinding = try CaptureDestinationBinding.load(for: source)
        try captureBinding?.validate(destination: destination)
        let expectedVolume = expectedVolumeIdentity ?? captureBinding?.volumeIdentity
        if let existing = try load(for: source) {
            guard existing.destination == destination else { throw PublicationError.contentConflict }
            if let expectedVolume, existing.destinationVolumeIdentity != expectedVolume {
                throw PublicationError.destinationUnavailable
            }
            return existing
        }
        let volume = try volumeIdentity(containing: destination)
        if let expectedVolume, volume != expectedVolume {
            throw PublicationError.destinationUnavailable
        }
        let digest = try fileDigest(source)
        guard digest.count > 0 else { throw PublicationError.missingMaster }
        guard try volumeIdentity(containing: destination) == volume else {
            throw PublicationError.destinationUnavailable
        }
        let intent = Self(version: 2, id: UUID(), source: source, destination: destination,
                          byteCount: digest.count, sha256: digest.hash, destinationVolumeIdentity: volume)
        let journal = journalURL(for: source)
        let temporary = journal.appendingPathExtension(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try DurableFileIO.writeAtomically(JSONEncoder().encode(intent), to: temporary)
        do { try renameExclusively(temporary, to: journal) }
        catch {
            guard let winner = try load(for: source), winner.destination == destination,
                  winner.byteCount == intent.byteCount, winner.sha256 == intent.sha256 else { throw error }
            return winner
        }
        try DurableFileIO.synchronizeFileAndParent(at: journal)
        return intent
    }

    public func matches(_ file: URL) throws -> Bool {
        let digest = try Self.fileDigest(file)
        return digest.count == byteCount && digest.hash == sha256
    }

    /// Serialize publication/recovery against this immutable journal inode.
    /// Callers must not keep writing the source after capture finalization.
    public func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(Self.journalURL(for: source).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    public func publish(removingSource: Bool = true) throws {
        try publish(removingSource: removingSource, synchronizeDestination: {
            try DurableFileIO.synchronizeFileAndParent(at: $0)
        })
    }

    func publish(removingSource: Bool, synchronizeDestination: (URL) throws -> Void) throws {
        try withExclusiveAccess {
            let manager = FileManager.default
            try verifyDestinationVolume()
            let sourceExists = manager.fileExists(atPath: source.path)
            if sourceExists, try !matches(source) { throw PublicationError.contentConflict }
            try DurableFileIO.synchronizeFileAndParent(at: Self.journalURL(for: source))
            if manager.fileExists(atPath: destination.path) {
                guard try matches(destination) else { throw PublicationError.contentConflict }
            } else {
                guard sourceExists else { throw PublicationError.missingMaster }
                try DurableFileIO.createDirectory(at: destination.deletingLastPathComponent())
                try verifyDestinationVolume()
                if manager.fileExists(atPath: stagingURL.path) {
                    // This unique, journal-owned staging file may be a partial
                    // copy from a killed process. Never recursively remove it.
                    let values = try stagingURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw PublicationError.contentConflict
                    }
                    if try !matches(stagingURL) { try manager.removeItem(at: stagingURL) }
                }
                if !manager.fileExists(atPath: stagingURL.path) {
                    try manager.copyItem(at: source, to: stagingURL)
                }
                guard try matches(stagingURL) else { throw PublicationError.contentConflict }
                try DurableFileIO.synchronizeFileAndParent(at: stagingURL)
                do { try Self.renameExclusively(stagingURL, to: destination) }
                catch {
                    guard manager.fileExists(atPath: destination.path), try matches(destination) else { throw error }
                }
            }
            try synchronizeDestination(destination)
            try verifyDestinationVolume()
            // A cleanup error leaves a journaled duplicate of the exact bytes,
            // not a failed publication or a new unbound recovery candidate.
            if removingSource, sourceExists { try? manager.removeItem(at: source) }
            try? manager.removeItem(at: stagingURL)
        }
    }

    /// Only after the Library row exists. Refuse cleanup if the destination or
    /// any remaining source differs from the intent's exact finalized bytes.
    public func finishLibraryCommit() throws {
        try withExclusiveAccess {
            try verifyDestinationVolume()
            try CaptureDestinationBinding.load(for: source)?.validate(destination: destination)
            guard try matches(destination) else { throw PublicationError.contentConflict }
            try DurableFileIO.synchronizeFileAndParent(at: destination)
            try verifyDestinationVolume()
            let manager = FileManager.default
            if manager.fileExists(atPath: source.path) {
                guard try matches(source) else { throw PublicationError.contentConflict }
                try manager.removeItem(at: source)
            }
            try? manager.removeItem(at: CaptureIntegrityReport.sidecarURL(for: source))
            if manager.fileExists(atPath: CaptureDestinationBinding.url(for: source).path) {
                try manager.removeItem(at: CaptureDestinationBinding.url(for: source))
            }
            try manager.removeItem(at: Self.journalURL(for: source))
            try DurableFileIO.synchronizeDirectory(at: source.deletingLastPathComponent())
        }
    }

    private static func renameExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func verifyDestinationVolume() throws {
        guard try Self.volumeIdentity(containing: destination) == destinationVolumeIdentity else {
            throw PublicationError.destinationUnavailable
        }
    }

    /// Bind before creating destination directories. A missing mount must not
    /// turn its former path into a new directory on the source filesystem.
    public static func volumeIdentity(containing destination: URL) throws -> String {
        var existing = destination.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw PublicationError.destinationUnavailable }
            existing = parent
        }
        let values = try existing.resourceValues(forKeys: [.volumeUUIDStringKey])
        if let uuid = values.volumeUUIDString, !uuid.isEmpty { return "uuid:" + uuid.lowercased() }
        // Filesystems without a persistent UUID can retry only while their
        // mounted device identity remains the same. Rebinding fails closed.
        var info = stat()
        guard stat(existing.path, &info) == 0 else { throw PublicationError.destinationUnavailable }
        return "device:" + String(info.st_dev)
    }

    private static func fileDigest(_ file: URL) throws -> (count: UInt64, hash: Data) {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PublicationError.contentConflict
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: UInt64 = 0
        while true {
            let readCount = try autoreleasepool {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                hasher.update(data: data)
                return data.count
            }
            if readCount == 0 { break }
            count += UInt64(readCount)
        }
        return (count, Data(hasher.finalize()))
    }
}
