import Foundation

/// Pre-flight check: do we have enough free space on the volume that will
/// host a download?
///
/// Spec requires 10 % headroom above the descriptor's total bytes so a model
/// download doesn't bring the user's disk to zero.
public struct DiskSpaceGuard: Sendable {
    /// Fractional headroom on top of `requiredBytes`. `0.1` = require
    /// `requiredBytes × 1.1` free. Tests override.
    public let headroom: Double

    /// Closure that resolves free bytes for a given URL. Defaults to a
    /// `FileManager.attributesOfFileSystem` reader; tests inject a closure
    /// returning a known value so the rejection path is deterministic and
    /// independent of the host's actual free disk.
    private let freeBytesProvider: @Sendable (URL) -> Int64?

    public init(
        fileManager: FileManager = .default,
        headroom: Double = 0.1,
        freeBytesProvider: (@Sendable (URL) -> Int64?)? = nil
    ) {
        self.headroom = headroom
        if let freeBytesProvider {
            self.freeBytesProvider = freeBytesProvider
        } else {
            let box = FileManagerBox(fileManager)
            self.freeBytesProvider = { url in
                guard let attrs = try? box.value.attributesOfFileSystem(forPath: url.path) else {
                    return nil
                }
                return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            }
        }
    }

    public struct Check: Equatable, Sendable {
        public let required: Int64   // requested bytes
        public let withHeadroom: Int64
        public let free: Int64
        public var hasSpace: Bool { free >= withHeadroom }
    }

    public func check(requiredBytes: Int64, at url: URL) -> Check {
        let withHeadroom = Int64(Double(requiredBytes) * (1.0 + headroom))
        let free = freeBytesProvider(url) ?? .max   // if we can't measure, don't block
        return Check(required: requiredBytes, withHeadroom: withHeadroom, free: free)
    }

    /// `nil` if the OS can't answer (unmounted volume, permission, etc.).
    public func freeBytes(on url: URL) -> Int64? {
        freeBytesProvider(url)
    }
}

private struct FileManagerBox: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}
