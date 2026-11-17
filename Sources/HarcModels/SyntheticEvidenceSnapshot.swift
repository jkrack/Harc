import Foundation
import CryptoKit
import Darwin

/// Inert synthetic-only copier. No production catalog bridge or model loader.
/// Protects against accidental corruption/concurrent updates, NOT hostile
/// same-user mutation. Open file descriptors do not make inodes immutable.
enum SyntheticEvidenceSnapshot {
    struct File: Sendable {
        let name: String
        let bytes: Int
        let sha256: String
    }
    enum Failure: Error { case invalidManifest, filesystem, unexpectedFiles, integrity }

    /// Small fixtures only. Executes synchronous bounded file work off-main and
    /// keeps cleanup ownership until the consumer (fake loader in tests) ends.
    static func withSnapshot<T: Sendable>(source: URL, scratch: URL, files: [File],
        beforeCopy: @escaping @Sendable () -> Void = {},
        beforeHandoff: @escaping @Sendable (URL) -> Void = { _ in },
        consume: @Sendable (URL) async throws -> T) async throws -> T {
        let preparation = Task.detached(priority: .utility) {
            try prepare(source: source, scratch: scratch, files: files, beforeCopy: beforeCopy)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await preparation.value
            defer { snapshot.cleanup() }
            try Task.checkCancellation()
            beforeHandoff(snapshot.url)
            try snapshot.validatePathBinding()
            try Task.checkCancellation()
            return try await consume(snapshot.url)
        } onCancel: { preparation.cancel() }
    }

    private final class Snapshot: @unchecked Sendable {
        let url: URL
        let parent: Int32
        let directory: Int32
        let name: String
        let files: [File]
        init(url: URL, parent: Int32, directory: Int32, name: String, files: [File]) {
            self.url = url; self.parent = parent; self.directory = directory
            self.name = name; self.files = files
        }
        func validatePathBinding() throws {
            let pathParent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard pathParent >= 0 else { throw Failure.filesystem }
            defer { close(pathParent) }
            let pathDirectory = openat(pathParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard pathDirectory >= 0 else { throw Failure.filesystem }
            defer { close(pathDirectory) }
            func same(_ a: Int32, _ b: Int32) -> Bool {
                var first = stat(); var second = stat()
                return fstat(a, &first) == 0 && fstat(b, &second) == 0 &&
                    first.st_dev == second.st_dev && first.st_ino == second.st_ino
            }
            guard same(parent, pathParent), same(directory, pathDirectory) else { throw Failure.integrity }
        }
        // Called exactly once by ownership scope; never recursively traverses
        // caller paths or follows symlinks, and never removes source files.
        func cleanup() {
            for file in files { _ = unlinkat(directory, file.name, 0) }
            // The child name may have been replaced after preparation. Never
            // remove a different directory merely because it reused our name.
            var retained = stat(); var named = stat()
            let ownsName = fstat(directory, &retained) == 0 &&
                fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                retained.st_dev == named.st_dev && retained.st_ino == named.st_ino
            if ownsName { _ = unlinkat(parent, name, AT_REMOVEDIR) }
            _ = close(directory)
            _ = close(parent)
        }
    }

    private static func names(_ fd: Int32, limit: Int) throws -> Set<String> {
        let copied = dup(fd)
        guard copied >= 0 else { throw Failure.filesystem }
        guard let directory = fdopendir(copied) else { close(copied); throw Failure.filesystem }
        defer { closedir(directory) }
        rewinddir(directory)
        var result = Set<String>()
        errno = 0
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                result.insert(name)
                guard result.count <= limit else { throw Failure.unexpectedFiles }
            }
            errno = 0
        }
        guard errno == 0 else { throw Failure.filesystem }
        return result
    }

    private static func prepare(source: URL, scratch: URL, files: [File], beforeCopy: @Sendable () -> Void) throws -> Snapshot {
        guard !files.isEmpty, files.count <= 16,
              Set(files.map(\.name)).count == files.count,
              files.allSatisfy({ file in
                  !file.name.isEmpty && file.name.utf8.count <= 128 && !file.name.hasPrefix(".") &&
                  file.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } &&
                  file.bytes >= 0 && file.bytes <= 1_048_576 && file.sha256.count == 64 &&
                  file.sha256.allSatisfy { "0123456789abcdef".contains($0) }
              }), files.reduce(0, { $0 + $1.bytes }) <= 4_194_304 else { throw Failure.invalidManifest }
        try Task.checkCancellation()
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let scratch = scratch.standardizedFileURL.resolvingSymlinksInPath()
        let src = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard src >= 0 else { throw Failure.filesystem }
        defer { close(src) }
        guard try names(src, limit: files.count) == Set(files.map(\.name)) else { throw Failure.unexpectedFiles }
        let parent = open(scratch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.filesystem }
        let name = "evidence-fixture-" + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { close(parent); throw Failure.filesystem }
        let destination = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard destination >= 0 else {
            unlinkat(parent, name, AT_REMOVEDIR); close(parent); throw Failure.filesystem
        }
        let snapshot = Snapshot(url: scratch.appendingPathComponent(name), parent: parent,
                                directory: destination, name: name, files: files)
        do {
            beforeCopy()
            try Task.checkCancellation()
            for file in files {
                try Task.checkCancellation()
                let input = openat(src, file.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard input >= 0 else { throw Failure.filesystem }
                defer { close(input) }
                var metadata = stat()
                guard fstat(input, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size == file.bytes else { throw Failure.integrity }
                let output = openat(destination, file.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw Failure.filesystem }
                defer { close(output) }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                var total = 0
                while true {
                    try Task.checkCancellation()
                    let count = read(input, &buffer, buffer.count)
                    guard count >= 0 else { throw Failure.filesystem }
                    if count == 0 { break }
                    total += count
                    guard total <= file.bytes else { throw Failure.integrity }
                    var written = 0
                    while written < count {
                        let amount = buffer.withUnsafeBytes {
                            write(output, $0.baseAddress!.advanced(by: written), count - written)
                        }
                        guard amount > 0 else { throw Failure.filesystem }
                        written += amount
                    }
                }
                guard total == file.bytes, lseek(output, 0, SEEK_SET) == 0 else { throw Failure.integrity }
                var hash = SHA256()
                var hashedBytes = 0
                while true {
                    try Task.checkCancellation()
                    let count = read(output, &buffer, buffer.count)
                    guard count >= 0 else { throw Failure.filesystem }
                    if count == 0 { break }
                    hashedBytes += count
                    guard hashedBytes <= file.bytes else { throw Failure.integrity }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard hashedBytes == file.bytes, digest == file.sha256 else { throw Failure.integrity }
            }
            guard try names(destination, limit: files.count) == Set(files.map(\.name)),
                  try names(src, limit: files.count) == Set(files.map(\.name)) else { throw Failure.unexpectedFiles }
            try Task.checkCancellation()
            return snapshot
        } catch { snapshot.cleanup(); throw error }
    }
}
