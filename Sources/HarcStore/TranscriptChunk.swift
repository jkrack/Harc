import Foundation

public struct TranscriptChunk: Sendable, Equatable, Identifiable {
    public var id: Int64?
    public var recordingID: Int64
    public var ordinal: Int
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var embedding: Data
    public var embeddingModelID: String
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        recordingID: Int64,
        ordinal: Int,
        startMs: Int,
        endMs: Int,
        text: String,
        embedding: Data,
        embeddingModelID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.ordinal = ordinal
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.embedding = embedding
        self.embeddingModelID = embeddingModelID
        self.createdAt = createdAt
    }
}
