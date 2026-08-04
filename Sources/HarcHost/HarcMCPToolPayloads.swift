import Foundation
import HarcStore

enum HarcMCPToolPayloads {
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func summary(for recording: Recording) -> RecordingSummary {
        RecordingSummary(
            recordingID: recording.id,
            wavPath: recording.wavPath,
            title: recording.displayTitle,
            startedAt: iso8601.string(from: recording.startedAt),
            endedAt: recording.endedAt.map(iso8601.string(from:)),
            durationSeconds: recording.endedAt.map {
                Int($0.timeIntervalSince(recording.startedAt))
            },
            tags: recording.tags,
            pinned: recording.pinned,
            hasSummary: recording.summaryMarkdown?.isEmpty == false
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

    static func detail(
        for recording: Recording,
        speakers: [Int: String]
    ) -> RecordingDetail {
        RecordingDetail(
            recordingID: recording.id,
            wavPath: recording.wavPath,
            markdownPath: OKFProjection.markdownURL(for: recording).path,
            title: recording.displayTitle,
            startedAt: iso8601.string(from: recording.startedAt),
            endedAt: recording.endedAt.map(iso8601.string(from:)),
            durationSeconds: recording.endedAt.map {
                Int($0.timeIntervalSince(recording.startedAt))
            },
            tags: recording.tags,
            speakers: speakers,
            summaryMarkdown: recording.summaryMarkdown,
            actionItemsMarkdown: recording.actionItemsMarkdown,
            notesMarkdown: recording.notesMarkdown,
            transcript: recording.transcriptText
        )
    }
}
