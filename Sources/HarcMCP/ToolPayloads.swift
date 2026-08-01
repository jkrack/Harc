import Foundation
import HarcStore

/// JSON payloads harc-mcp returns to agents. Deliberately flat and
/// self-describing — the tool results are consumed by a model, not a UI.
enum ToolPayloads {

    struct SearchHit: Codable {
        let recordingID: Int64?
        let wavPath: String
        let title: String
        let startedAt: String
        let snippet: String
        let score: Double
    }

    struct RecordingSummary: Codable {
        let recordingID: Int64?
        let wavPath: String
        let title: String
        let startedAt: String
        let endedAt: String?
        let durationSeconds: Int?
        let tags: [String]
        let pinned: Bool
        let hasSummary: Bool
    }

    struct RecordingDetail: Codable {
        let recordingID: Int64?
        let wavPath: String
        let markdownPath: String
        let title: String
        let startedAt: String
        let endedAt: String?
        let durationSeconds: Int?
        let tags: [String]
        let speakers: [Int: String]
        let summaryMarkdown: String?
        let actionItemsMarkdown: String?
        let notesMarkdown: String?
        let transcript: String?
    }

    static var iso8601: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func summary(for rec: Recording) -> RecordingSummary {
        RecordingSummary(
            recordingID: rec.id,
            wavPath: rec.wavPath,
            title: rec.displayTitle,
            startedAt: iso8601.string(from: rec.startedAt),
            endedAt: rec.endedAt.map(iso8601.string(from:)),
            durationSeconds: rec.endedAt.map { Int($0.timeIntervalSince(rec.startedAt)) },
            tags: rec.tags,
            pinned: rec.pinned,
            hasSummary: rec.summaryMarkdown?.isEmpty == false
        )
    }

    static func hit(for hit: TranscriptHit) -> SearchHit {
        SearchHit(
            recordingID: hit.recording.id,
            wavPath: hit.recording.wavPath,
            title: hit.recording.displayTitle,
            startedAt: iso8601.string(from: hit.recording.startedAt),
            snippet: hit.snippet,
            score: hit.score
        )
    }

    static func detail(for rec: Recording, speakers: [Int: String]) -> RecordingDetail {
        RecordingDetail(
            recordingID: rec.id,
            wavPath: rec.wavPath,
            markdownPath: OKFProjection.markdownURL(for: rec).path,
            title: rec.displayTitle,
            startedAt: iso8601.string(from: rec.startedAt),
            endedAt: rec.endedAt.map(iso8601.string(from:)),
            durationSeconds: rec.endedAt.map { Int($0.timeIntervalSince(rec.startedAt)) },
            tags: rec.tags,
            speakers: speakers,
            summaryMarkdown: rec.summaryMarkdown,
            actionItemsMarkdown: rec.actionItemsMarkdown,
            notesMarkdown: rec.notesMarkdown,
            transcript: rec.transcriptText
        )
    }
}
