import Foundation

public struct Note: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var recordings: [String]
    public var attachments: [NoteAttachment]
    public var people: [String]
    public var derivedFrom: String?
    public var folderPath: String?
    public var pinned: Bool
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var fileURL: URL

    public init(
        id: String,
        title: String,
        body: String,
        tags: [String] = [],
        recordings: [String] = [],
        attachments: [NoteAttachment] = [],
        people: [String] = [],
        derivedFrom: String? = nil,
        folderPath: String? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        fileURL: URL
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.recordings = recordings
        self.attachments = attachments
        self.people = people
        self.derivedFrom = derivedFrom
        self.folderPath = folderPath
        self.pinned = pinned
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileURL = fileURL
    }

    public var preview: String {
        body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

public enum NoteAttachmentCaptionStatus: String, Codable, Equatable, Hashable, Sendable {
    case unavailable
    case pending
    case captioned
    case failed
}

public struct NoteAttachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var filename: String
    public var relativePath: String
    public var mimeType: String
    public var byteCount: Int
    public var altText: String
    public var caption: String?
    public var captionedAt: Date?
    public var captionModelID: String?
    public var captionStatus: NoteAttachmentCaptionStatus
    public var createdAt: Date

    public init(
        id: String,
        kind: String = "image",
        filename: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        altText: String,
        caption: String? = nil,
        captionedAt: Date? = nil,
        captionModelID: String? = nil,
        captionStatus: NoteAttachmentCaptionStatus = .unavailable,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.altText = altText
        self.caption = caption
        self.captionedAt = captionedAt
        self.captionModelID = captionModelID
        self.captionStatus = captionStatus
        self.createdAt = createdAt
    }

    public var searchableText: String {
        [altText, caption, filename]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
