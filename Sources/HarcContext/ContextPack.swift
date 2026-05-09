import Foundation
import HarcStore

public enum ContextIntent: String, Sendable, Codable, Equatable {
    case general
    case person
    case project
    case decision
    case actionItems
    case meetingPrep
}

public enum ContextBlockKind: String, Sendable, Codable, Equatable {
    case directEvidence
    case summary
    case actionItems
}

public struct ContextSource: Sendable, Codable, Equatable, Identifiable {
    public var recordingID: Int64
    public var title: String
    public var startedAt: Date
    public var wavPath: String
    public var txtPath: String?
    public var jsonPath: String?

    public var id: Int64 { recordingID }

    public init(recording: Recording) {
        self.recordingID = recording.id ?? -1
        self.title = recording.displayTitle
        self.startedAt = recording.startedAt
        self.wavPath = recording.wavPath
        self.txtPath = recording.txtPath
        self.jsonPath = recording.jsonPath
    }
}

public struct ContextBlock: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var kind: ContextBlockKind
    public var source: ContextSource
    public var text: String
    public var score: Double

    public init(
        id: String,
        kind: ContextBlockKind,
        source: ContextSource,
        text: String,
        score: Double
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.text = text
        self.score = score
    }
}

public struct ContextPack: Sendable, Codable, Equatable {
    public var query: String
    public var retrievalQueries: [String]
    public var intent: ContextIntent
    public var generatedAt: Date
    public var blocks: [ContextBlock]

    public init(
        query: String,
        retrievalQueries: [String] = [],
        intent: ContextIntent,
        generatedAt: Date = Date(),
        blocks: [ContextBlock]
    ) {
        self.query = query
        self.retrievalQueries = retrievalQueries
        self.intent = intent
        self.generatedAt = generatedAt
        self.blocks = blocks
    }

    public var sources: [ContextSource] {
        var seen: Set<Int64> = []
        var ordered: [ContextSource] = []
        for block in blocks where !seen.contains(block.source.recordingID) {
            seen.insert(block.source.recordingID)
            ordered.append(block.source)
        }
        return ordered
    }

    public var isEmpty: Bool { blocks.isEmpty }
}
