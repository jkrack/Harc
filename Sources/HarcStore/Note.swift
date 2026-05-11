import Foundation

public struct Note: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var recordings: [String]
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
