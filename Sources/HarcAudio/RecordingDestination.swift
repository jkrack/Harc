import Foundation
import HarcCore

public struct RecordingDestination: Sendable {
    public let baseDirectory: URL
    private let volumeIdentity: String?

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        // Freeze the filesystem identity when capture/import is configured,
        // before finalization can observe a vanished mount as a local path.
        self.volumeIdentity = try? RecordingPublication.volumeIdentity(
            containing: baseDirectory.appendingPathComponent(".harc-volume-probe")
        )
    }

    public func validate() throws {
        guard let volumeIdentity,
              try RecordingPublication.volumeIdentity(containing: baseDirectory.appendingPathComponent(".harc-volume-probe")) == volumeIdentity else {
            throw RecordingPublication.PublicationError.destinationUnavailable
        }
    }

    public func persistBinding(for source: URL) throws {
        try validate()
        guard let volumeIdentity else { throw RecordingPublication.PublicationError.destinationUnavailable }
        try CaptureDestinationBinding(source: source, baseDirectory: baseDirectory,
                                      volumeIdentity: volumeIdentity).save()
    }

    func restoringBinding(for source: URL) throws -> Self {
        guard let binding = try CaptureDestinationBinding.load(for: source) else { return self }
        try binding.validate()
        return Self(baseDirectory: binding.baseDirectory, volumeIdentity: binding.volumeIdentity)
    }

    private init(baseDirectory: URL, volumeIdentity: String) {
        self.baseDirectory = baseDirectory
        self.volumeIdentity = volumeIdentity
    }

    public func preparePublication(from source: URL, to destination: URL) throws -> RecordingPublication {
        try validate()
        return try RecordingPublication.prepare(source: source, destination: destination,
                                                expectedVolumeIdentity: volumeIdentity)
    }

    /// Default base: `~/Documents/Harc/`. Plan 5 will replace this with user-configurable.
    public static func defaultBaseDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/Harc", isDirectory: true)
    }

    /// The in-progress cache path for a recording, e.g. `~/Library/Caches/Harc/recordings/<uuid>.wav`.
    /// Fresh UUID every call — callers keep the URL for the duration of one recording.
    public static func cachePath() -> URL {
        cacheDirectory().appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// Directory that holds in-progress recordings before they are finalized
    /// into the user's public destination folder.
    public static func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Harc/recordings", isDirectory: true)
    }

    /// The final public path for a recording started at `date`.
    /// Shape: `<base>/YYYY/YYYY-MM-DD/HH-mm-ss.wav`. Appends `-1`, `-2`, … on collision.
    public func publicPath(for date: Date) throws -> URL {
        try validate()
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
        while FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(atPath: CaptureIntegrityReport.sidecarURL(for: candidate).path) {
            candidate = dayDir.appendingPathComponent("\(base)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// Move a finished recording into the destination hierarchy, creating parent directories.
    /// Refuse an occupied destination, including a collision after publicPath
    /// was selected. Publication never has authority to replace another master.
    public static func atomicMove(from src: URL, to dst: URL) throws {
        try RecordingPublication.prepare(source: src, destination: dst).publish()
    }
}
