import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit filesystem barriers for recoverable metadata and publication.
/// A successful call confirms the OS accepted each barrier; physical power-loss
/// qualification and the storage device's implementation remain separate gates.
public enum DurableFileIO {
    /// Create one component at a time, syncing each parent before proceeding.
    /// Existing directories also require their parent barrier: they may be the
    /// result of an earlier creation whose synchronization failed.
    public static func createDirectory(at directory: URL) throws {
        try createDirectory(at: directory, synchronizeParent: synchronizeDirectory(at:))
    }

    static func createDirectory(at directory: URL, synchronizeParent: (URL) throws -> Void) throws {
        try validate(directory)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw failure(ENOTDIR, at: directory) }
            try synchronizeParent(directory.deletingLastPathComponent())
            return
        }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { throw failure(ENOENT, at: directory) }
        try createDirectory(at: parent, synchronizeParent: synchronizeParent)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            // A concurrent creator can win after the existence check. Accept
            // only an actual directory, and still require the same barrier.
            let nsError = error as NSError
            guard (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteFileExists.rawValue)
                    || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST)),
                  manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw error }
        }
        try synchronizeParent(parent)
    }

    /// Sync both the file and its name in the parent directory, then request a
    /// drive-cache flush on Apple platforms. Do not silently downgrade an error.
    public static func synchronizeFileAndParent(at file: URL) throws {
        try validate(file)
        let descriptor = open(file.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(errno, at: file) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure(errno, at: file) }
        try synchronizeDirectory(at: file.deletingLastPathComponent())
        #if canImport(Darwin)
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw failure(errno, at: file) }
        #endif
    }

    public static func synchronizeDirectory(at directory: URL) throws {
        try validate(directory)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(errno, at: directory) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure(errno, at: directory) }
    }

    public static func writeAtomically(_ data: Data, to file: URL) throws {
        try validate(file)
        try createDirectory(at: file.deletingLastPathComponent())
        try data.write(to: file, options: .atomic)
        try synchronizeFileAndParent(at: file)
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private static func failure(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
