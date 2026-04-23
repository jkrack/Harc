import Foundation

/// Pre-flight check: do we have enough free space on the volume that will
/// host a download?
///
/// Spec requires 10 % headroom above the descriptor's total bytes so a model
/// download doesn't bring the user's disk to zero.
public struct DiskSpaceGuard: Sendable {
    /// `FileManager` isn't `Sendable` in the SDK, so we keep a reference
    /// behind an unchecked marker. `FileManager.default` is effectively
    /// thread-safe for the read-only attribute queries we do; injected
    /// instances in tests are used from a single thread.
    private let _fileManagerBox: FileManagerBox
    public var fileManager: FileManager { _fileManagerBox.value }

    /// Fractional headroom on top of `requiredBytes`. `0.1` = require
    /// `requiredBytes × 1.1` free. Tests override.
    public let headroom: Double

    public init(fileManager: FileManager = .default, headroom: Double = 0.1) {
        self._fileManagerBox = FileManagerBox(fileManager)
        self.headroom = headroom
    }

    public struct Check: Equatable, Sendable {
        public let required: Int64   // requested bytes
        public let withHeadroom: Int64
        public let free: Int64
        public var hasSpace: Bool { free >= withHeadroom }
    }

    public func check(requiredBytes: Int64, at url: URL) -> Check {
        let withHeadroom = Int64(Double(requiredBytes) * (1.0 + headroom))
        let free = freeBytes(on: url) ?? .max   // if we can't measure, don't block
        return Check(required: requiredBytes, withHeadroom: withHeadroom, free: free)
    }

    /// `nil` if the OS can't answer (unmounted volume, permission, etc.).
    public func freeBytes(on url: URL) -> Int64? {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: url.path)
            if let v = attrs[.systemFreeSize] as? NSNumber {
                return v.int64Value
            }
            return nil
        } catch {
            return nil
        }
    }
}

private struct FileManagerBox: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}
