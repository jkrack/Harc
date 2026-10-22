import Foundation

/// Capture observations without an installation identity or filesystem path.
/// Frame offsets mark detection in the saved PCM, not an invented duration of
/// missing audio. Repeated observations are bounded by source and reason.
public struct CaptureIntegrityReport: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable { case microphone, systemAudio, mixed }
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case bufferOverrun, conversionFailed, sourceInterrupted, sourceStopped, writerFailure, drainTimedOut
    }
    public struct Issue: Codable, Equatable, Hashable, Sendable {
        public let source: Source
        public let reason: Reason
        public let frameOffset: UInt64
        public let monotonicNanoseconds: UInt64
        public let detectedAt: Date
        public fileprivate(set) var lastDetectedAt: Date
        public fileprivate(set) var occurrences: UInt64
    }
    public private(set) var issues: [Issue] = []
    public var hasIssues: Bool { !issues.isEmpty }
    public var warningText: String? {
        hasIssues ? "Some audio may be missing. The saved recording contains the audio Harc could preserve." : nil
    }
    public init() {}

    /// Returns true for a newly observed category. Counts saturate rather than
    /// wrapping during a prolonged failing source.
    @discardableResult
    public mutating func record(
        source: Source, reason: Reason, frameOffset: UInt64,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        at date: Date = Date()
    ) -> Bool {
        if let index = issues.firstIndex(where: { $0.source == source && $0.reason == reason }) {
            issues[index].lastDetectedAt = max(issues[index].lastDetectedAt, date)
            if issues[index].occurrences < .max { issues[index].occurrences += 1 }
            return false
        }
        issues.append(Issue(source: source, reason: reason, frameOffset: frameOffset,
                            monotonicNanoseconds: monotonicNanoseconds, detectedAt: date,
                            lastDetectedAt: date, occurrences: 1))
        return true
    }

    private enum CodingKeys: String, CodingKey { case version, issues }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try container.decode([Issue].self, forKey: .issues)
        guard decoded.count <= Source.allCases.count * Reason.allCases.count,
              Set(decoded.map { "\($0.source.rawValue):\($0.reason.rawValue)" }).count == decoded.count,
              decoded.allSatisfy({ $0.occurrences > 0 && $0.lastDetectedAt >= $0.detectedAt })
        else { throw CocoaError(.fileReadCorruptFile) }
        issues = decoded
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(issues, forKey: .issues)
    }

    public static func sidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("capture-issues.json")
    }
    public static func load(nextTo audio: URL) throws -> Self {
        let data: Data
        do { data = try Data(contentsOf: sidecarURL(for: audio)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Self() }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func save(nextTo audio: URL) throws {
        let url = Self.sidecarURL(for: audio)
        try DurableFileIO.writeAtomically(JSONEncoder().encode(self), to: url)
    }
    /// Publish integrity evidence before relinquishing the source master.
    public static func carry(from source: URL, to destination: URL) throws -> Self {
        let report = try load(nextTo: source)
        let existing = try load(nextTo: destination)
        guard !existing.hasIssues || existing == report else { throw CocoaError(.fileWriteFileExists) }
        if report.hasIssues { try report.save(nextTo: destination) }
        return report
    }
}
