import Foundation
import Darwin

/// Local capture authority, persisted before audio starts and kept until the
/// Library commit. It cannot be rebound merely because preferences changed.
public struct CaptureDestinationBinding: Codable, Equatable, Sendable {
    public let version: Int
    public let source: URL
    public let baseDirectory: URL
    public let volumeIdentity: String

    public init(source: URL, baseDirectory: URL, volumeIdentity: String) {
        self.version = 1
        self.source = source.standardized
        self.baseDirectory = baseDirectory.standardized
        self.volumeIdentity = volumeIdentity
    }

    public static func url(for source: URL) -> URL { source.appendingPathExtension("destination.json") }

    public static func load(for source: URL) throws -> Self? {
        let path = url(for: source)
        let data: Data
        do {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? .max) <= 65_536 else { throw RecordingPublication.PublicationError.invalidJournal }
            data = try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let binding = try JSONDecoder().decode(Self.self, from: data)
        guard binding.version == 1, binding.source == source.standardized,
              binding.source.isFileURL, binding.baseDirectory.isFileURL,
              binding.baseDirectory == binding.baseDirectory.standardized,
              !binding.source.path.contains("\0"), !binding.baseDirectory.path.contains("\0"),
              !binding.volumeIdentity.isEmpty else { throw RecordingPublication.PublicationError.invalidJournal }
        return binding
    }

    public func validate(destination: URL? = nil) throws {
        let target = destination ?? baseDirectory.appendingPathComponent(".harc-volume-probe")
        guard target.isFileURL,
              target.standardized.path.hasPrefix(baseDirectory.path.hasSuffix("/") ? baseDirectory.path : baseDirectory.path + "/"),
              try RecordingPublication.volumeIdentity(containing: target) == volumeIdentity else {
            throw RecordingPublication.PublicationError.destinationUnavailable
        }
    }

    public func save() throws {
        try validate()
        if let existing = try Self.load(for: source) {
            guard existing == self else { throw RecordingPublication.PublicationError.contentConflict }
            try DurableFileIO.synchronizeFileAndParent(at: Self.url(for: source))
            return
        }
        let path = Self.url(for: source)
        let temporary = path.appendingPathExtension(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try DurableFileIO.writeAtomically(JSONEncoder().encode(self), to: temporary)
        guard renamex_np(temporary.path, path.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try DurableFileIO.synchronizeFileAndParent(at: path)
    }
}
