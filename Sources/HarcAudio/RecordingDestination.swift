import Foundation

public struct RecordingDestination: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Default base: `~/Documents/Harc/`. Plan 5 will replace this with user-configurable.
    public static func defaultBaseDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/Harc", isDirectory: true)
    }

    /// The in-progress cache path for a recording, e.g. `~/Library/Caches/Harc/recordings/<uuid>.wav`.
    /// Fresh UUID every call — callers keep the URL for the duration of one recording.
    public static func cachePath() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Harc/recordings", isDirectory: true)
        return dir.appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// The final public path for a recording started at `date`.
    /// Shape: `<base>/YYYY/YYYY-MM-DD/HH-mm-ss.wav`. Appends `-1`, `-2`, … on collision.
    public func publicPath(for date: Date) throws -> URL {
        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: date))
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        let hour = String(format: "%02d", cal.component(.hour, from: date))
        let minute = String(format: "%02d", cal.component(.minute, from: date))
        let second = String(format: "%02d", cal.component(.second, from: date))

        let dayDir = baseDirectory
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day)", isDirectory: true)
        let base = "\(hour)-\(minute)-\(second)"

        var candidate = dayDir.appendingPathComponent("\(base).wav")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dayDir.appendingPathComponent("\(base)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// Move a finished recording into the destination hierarchy, creating parent directories.
    /// Uses `replaceItem` for atomicity across the rename + potential overwrite.
    public static func atomicMove(from src: URL, to dst: URL) throws {
        let parent = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // replaceItem handles both pre-existing dst and fresh dst.
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: src)
        } else {
            try FileManager.default.moveItem(at: src, to: dst)
        }
    }
}
