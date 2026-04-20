import Foundation

/// Neutral input shape consumed by every exporter. Renderers are pure
/// functions over this type — no filesystem, no AppKit, no GRDB.
public struct ExportInput: Equatable, Sendable {
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int?
    public let tags: [String]
    public let speakerNames: [Int: String]
    public let segments: [Segment]

    public init(
        title: String,
        startedAt: Date,
        durationSeconds: Int?,
        tags: [String] = [],
        speakerNames: [Int: String] = [:],
        segments: [Segment]
    ) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.speakerNames = speakerNames
        self.segments = segments
    }

    public struct Segment: Equatable, Sendable {
        /// 0-based speaker id from diarization. `nil` means "no speaker
        /// attribution" (single-speaker or diarization-off). Renderers map
        /// to 1-based labels ("Speaker 1").
        public let speaker: Int?
        /// Already trimmed, non-empty, \r stripped.
        public let text: String

        public init(speaker: Int?, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// True if any segment has a non-nil speaker id.
    public var isDiarized: Bool {
        segments.contains { $0.speaker != nil }
    }
}
