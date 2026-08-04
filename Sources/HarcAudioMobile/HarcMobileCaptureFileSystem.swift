import Darwin
import Foundation

enum HarcMobileCaptureFileSystem {
    static func requireSafeDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if FileManager.default.fileExists(atPath: url.path) {
            var information = stat()
            guard lstat(url.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR,
                  information.st_uid == geteuid() else {
                throw HarcMobileCaptureStorageError.unsafeArtifact(url.path)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    static func createExclusiveFile(_ url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw HarcMobileCaptureStorageError.destinationExists(url.path)
            }
            throw posix("open", errno)
        }
        return descriptor
    }

    static func openExistingRegularFile(
        _ url: URL,
        flags: Int32
    ) throws -> Int32 {
        let descriptor = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("open", errno) }
        do {
            try validateRegularFile(descriptor, expectedURL: url)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func validateRegularFile(
        _ descriptor: Int32,
        expectedURL: URL
    ) throws {
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(expectedURL.path, &pathInfo) == 0,
              descriptorInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              descriptorInfo.st_uid == geteuid(),
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino else {
            throw HarcMobileCaptureStorageError.unsafeArtifact(
                expectedURL.path
            )
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw posix("write", errno)
                }
            }
        }
    }

    static func pwriteAll(
        _ data: Data,
        to descriptor: Int32,
        offset initialOffset: off_t
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written,
                    initialOffset + off_t(written)
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw posix("pwrite", errno)
                }
            }
        }
    }

    static func synchronize(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw posix("fsync", errno) }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posix("open directory", errno) }
        defer { Darwin.close(descriptor) }
        try synchronize(descriptor)
    }

    static func atomicWrite(
        _ data: Data,
        to destination: URL
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).partial")
        let descriptor = try createExclusiveFile(temporary)
        var openDescriptor = true
        defer {
            if openDescriptor { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try writeAll(data, to: descriptor)
        try synchronize(descriptor)
        try validateRegularFile(descriptor, expectedURL: temporary)
        guard Darwin.close(descriptor) == 0 else { throw posix("close", errno) }
        openDescriptor = false

        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try openExistingRegularFile(destination, flags: O_RDONLY)
            Darwin.close(existing)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw posix("rename", errno)
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func renameExclusive(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw HarcMobileCaptureStorageError.destinationExists(
                destination.path
            )
        }
        guard rename(source.path, destination.path) == 0 else {
            throw posix("rename", errno)
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func posix(_ operation: String, _ code: Int32)
        -> HarcMobileCaptureStorageError {
        .posix(operation: operation, code: code)
    }
}
