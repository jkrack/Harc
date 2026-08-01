import Foundation
import GRDB

/// A virtual day session — a grouping row over untouched recordings.
/// Mirrors the `sessions` table. A session carries its own title and
/// combined summary; audio, transcripts, and timestamps stay on the
/// member recordings.
public struct Session: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int64?
    /// Local day the session belongs to, `"YYYY-MM-DD"`. Matches the
    /// destination folder's day-directory name; members are same-day by
    /// construction.
    public var day: String
    public var title: String?
    public var summaryMarkdown: String?
    public var actionItemsMarkdown: String?
    /// Free-form user/agent notes, mirroring `Recording.notesMarkdown`.
    public var notesMarkdown: String?
    public var summaryModelID: String?
    public var summaryGeneratedAt: Date?
    public var summarySourceWordCount: Int?
    public var summaryStatusKind: RecordingSummaryStatusKind?
    public var summaryStatusMessage: String?
    public var summaryStatusUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        day: String,
        title: String? = nil,
        summaryMarkdown: String? = nil,
        actionItemsMarkdown: String? = nil,
        notesMarkdown: String? = nil,
        summaryModelID: String? = nil,
        summaryGeneratedAt: Date? = nil,
        summarySourceWordCount: Int? = nil,
        summaryStatusKind: RecordingSummaryStatusKind? = nil,
        summaryStatusMessage: String? = nil,
        summaryStatusUpdatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.day = day
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.actionItemsMarkdown = actionItemsMarkdown
        self.notesMarkdown = notesMarkdown
        self.summaryModelID = summaryModelID
        self.summaryGeneratedAt = summaryGeneratedAt
        self.summarySourceWordCount = summarySourceWordCount
        self.summaryStatusKind = summaryStatusKind
        self.summaryStatusMessage = summaryStatusMessage
        self.summaryStatusUpdatedAt = summaryStatusUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Display title: user's custom title if set, else "Session · <day>".
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return "Session · \(day)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int64.self, forKey: .id)
        self.day = try c.decode(String.self, forKey: .day)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.summaryMarkdown = try c.decodeIfPresent(String.self, forKey: .summaryMarkdown)
        self.actionItemsMarkdown = try c.decodeIfPresent(String.self, forKey: .actionItemsMarkdown)
        self.notesMarkdown = try c.decodeIfPresent(String.self, forKey: .notesMarkdown)
        self.summaryModelID = try c.decodeIfPresent(String.self, forKey: .summaryModelID)
        if let ms = try c.decodeIfPresent(Int64.self, forKey: .summaryGeneratedAt) {
            self.summaryGeneratedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            self.summaryGeneratedAt = nil
        }
        self.summarySourceWordCount = try c.decodeIfPresent(Int.self, forKey: .summarySourceWordCount)
        if let rawStatus = try c.decodeIfPresent(String.self, forKey: .summaryStatusKind) {
            self.summaryStatusKind = RecordingSummaryStatusKind(rawValue: rawStatus)
        } else {
            self.summaryStatusKind = nil
        }
        self.summaryStatusMessage = try c.decodeIfPresent(String.self, forKey: .summaryStatusMessage)
        if let ms = try c.decodeIfPresent(Int64.self, forKey: .summaryStatusUpdatedAt) {
            self.summaryStatusUpdatedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            self.summaryStatusUpdatedAt = nil
        }
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(day, forKey: .day)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
        try c.encodeIfPresent(actionItemsMarkdown, forKey: .actionItemsMarkdown)
        try c.encodeIfPresent(notesMarkdown, forKey: .notesMarkdown)
        try c.encodeIfPresent(summaryModelID, forKey: .summaryModelID)
        if let d = summaryGeneratedAt {
            try c.encode(Int64(d.timeIntervalSince1970 * 1000), forKey: .summaryGeneratedAt)
        } else {
            try c.encodeNil(forKey: .summaryGeneratedAt)
        }
        try c.encodeIfPresent(summarySourceWordCount, forKey: .summarySourceWordCount)
        try c.encodeIfPresent(summaryStatusKind?.rawValue, forKey: .summaryStatusKind)
        try c.encodeIfPresent(summaryStatusMessage, forKey: .summaryStatusMessage)
        if let d = summaryStatusUpdatedAt {
            try c.encode(Int64(d.timeIntervalSince1970 * 1000), forKey: .summaryStatusUpdatedAt)
        } else {
            try c.encodeNil(forKey: .summaryStatusUpdatedAt)
        }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

extension Session: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"

    private enum CodingKeys: String, CodingKey {
        case id
        case day
        case title
        case summaryMarkdown = "summary_markdown"
        case actionItemsMarkdown = "action_items_markdown"
        case notesMarkdown = "notes_markdown"
        case summaryModelID = "summary_model_id"
        case summaryGeneratedAt = "summary_generated_at"
        case summarySourceWordCount = "summary_source_word_count"
        case summaryStatusKind = "summary_status_kind"
        case summaryStatusMessage = "summary_status_message"
        case summaryStatusUpdatedAt = "summary_status_updated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public enum Columns {
        static let id = Column("id")
        static let day = Column("day")
        static let title = Column("title")
        static let summaryMarkdown = Column("summary_markdown")
        static let actionItemsMarkdown = Column("action_items_markdown")
        static let notesMarkdown = Column("notes_markdown")
        static let summaryModelID = Column("summary_model_id")
        static let summaryGeneratedAt = Column("summary_generated_at")
        static let summarySourceWordCount = Column("summary_source_word_count")
        static let summaryStatusKind = Column("summary_status_kind")
        static let summaryStatusMessage = Column("summary_status_message")
        static let summaryStatusUpdatedAt = Column("summary_status_updated_at")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }
}

/// The local-day key used by `sessions.day`, e.g. `"2026-07-31"`.
public enum SessionDay {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
