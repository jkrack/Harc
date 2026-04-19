import Foundation
import GRDB

/// A single recording row. Mirrors the `recordings` table.
public struct Recording: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int64?
    public var wavPath: String
    public var txtPath: String?
    public var jsonPath: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String?
    public var transcriptText: String?
    public var suggestedTitle: String?
    public var pinned: Bool
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        wavPath: String,
        txtPath: String? = nil,
        jsonPath: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        transcriptText: String? = nil,
        suggestedTitle: String? = nil,
        pinned: Bool = false,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.wavPath = wavPath
        self.txtPath = txtPath
        self.jsonPath = jsonPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.transcriptText = transcriptText
        self.suggestedTitle = suggestedTitle
        self.pinned = pinned
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Display title: user's custom title if set; else the NLTagger-derived
    /// suggestion if present; else derived from startedAt.
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let s = suggestedTitle, !s.isEmpty {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            return "\(fmt.string(from: startedAt)) — \(s)"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: startedAt)
    }

    /// First ~120 chars of transcript, trimmed. Empty string if no transcript.
    public var preview: String {
        guard let text = transcriptText else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }
}

extension Recording: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recordings"

    // Map Swift camelCase property names to snake_case column names.
    private enum CodingKeys: String, CodingKey {
        case id
        case wavPath = "wav_path"
        case txtPath = "txt_path"
        case jsonPath = "json_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case transcriptText = "transcript_text"
        case suggestedTitle = "suggested_title"
        case pinned
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public enum Columns {
        static let id = Column("id")
        static let wavPath = Column("wav_path")
        static let txtPath = Column("txt_path")
        static let jsonPath = Column("json_path")
        static let startedAt = Column("started_at")
        static let endedAt = Column("ended_at")
        static let title = Column("title")
        static let transcriptText = Column("transcript_text")
        static let suggestedTitle = Column("suggested_title")
        static let pinned = Column("pinned")
        static let deletedAt = Column("deleted_at")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }
}
