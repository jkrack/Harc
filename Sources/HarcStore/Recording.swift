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
    public var tags: [String] = []
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
        tags: [String] = [],
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
        self.tags = tags
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int64.self, forKey: .id)
        self.wavPath = try c.decode(String.self, forKey: .wavPath)
        self.txtPath = try c.decodeIfPresent(String.self, forKey: .txtPath)
        self.jsonPath = try c.decodeIfPresent(String.self, forKey: .jsonPath)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.transcriptText = try c.decodeIfPresent(String.self, forKey: .transcriptText)
        self.suggestedTitle = try c.decodeIfPresent(String.self, forKey: .suggestedTitle)
        if let json = try c.decodeIfPresent(String.self, forKey: .tags),
           let data = json.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.tags = arr
        } else {
            self.tags = []
        }
        self.pinned = try c.decode(Bool.self, forKey: .pinned)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(wavPath, forKey: .wavPath)
        try c.encodeIfPresent(txtPath, forKey: .txtPath)
        try c.encodeIfPresent(jsonPath, forKey: .jsonPath)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(transcriptText, forKey: .transcriptText)
        try c.encodeIfPresent(suggestedTitle, forKey: .suggestedTitle)
        if tags.isEmpty {
            try c.encodeNil(forKey: .tags)
        } else if let data = try? JSONEncoder().encode(tags),
                  let s = String(data: data, encoding: .utf8) {
            try c.encode(s, forKey: .tags)
        } else {
            try c.encodeNil(forKey: .tags)
        }
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
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
        case tags
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
        static let tags = Column("tags")
        static let pinned = Column("pinned")
        static let deletedAt = Column("deleted_at")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }
}
