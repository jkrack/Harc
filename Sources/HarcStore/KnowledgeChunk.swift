import Foundation

public enum KnowledgeSourceKind: String, Sendable, Codable, Equatable {
    case recording
    case note
    case rawFile
    case repoFile
    case wikiPage
}

public struct KnowledgeChunk: Sendable, Equatable, Identifiable {
    public var id: Int64?
    public var sourceKind: KnowledgeSourceKind
    public var sourceID: String
    public var ordinal: Int
    public var title: String
    public var text: String
    public var embedding: Data
    public var embeddingModelID: String
    public var contentHash: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        sourceKind: KnowledgeSourceKind,
        sourceID: String,
        ordinal: Int,
        title: String,
        text: String,
        embedding: Data,
        embeddingModelID: String,
        contentHash: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.title = title
        self.text = text
        self.embedding = embedding
        self.embeddingModelID = embeddingModelID
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
