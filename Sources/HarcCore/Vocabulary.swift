import Foundation

public struct VocabularyEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: String
    public var to: String
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        from: String,
        to: String,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public var entries: [VocabularyEntry]

    public init(entries: [VocabularyEntry] = []) {
        self.entries = entries
    }

    public static let empty = Vocabulary(entries: [])
}
