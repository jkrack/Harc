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
    case synthesis
    case directEvidence
    case summary
    case actionItems
}

public enum ContextSourceKind: String, Sendable, Codable, Equatable {
    case recording
    case note
    case rawFile
    case repoFile
    case wikiPage
}

public struct ContextSource: Sendable, Codable, Equatable, Identifiable {
    public var kind: ContextSourceKind
    public var sourceID: String
    public var recordingID: Int64
    public var title: String
    public var startedAt: Date
    public var wavPath: String
    public var txtPath: String?
    public var jsonPath: String?
    public var noteID: String?
    public var notePath: String?

    public var id: String { "\(kind.rawValue):\(sourceID)" }

    public init(recording: Recording) {
        self.kind = .recording
        self.recordingID = recording.id ?? -1
        self.sourceID = recording.id.map(String.init) ?? recording.wavPath
        self.title = recording.displayTitle
        self.startedAt = recording.startedAt
        self.wavPath = recording.wavPath
        self.txtPath = recording.txtPath
        self.jsonPath = recording.jsonPath
        self.noteID = nil
        self.notePath = nil
    }

    public init(note: Note) {
        self.kind = .note
        self.sourceID = note.id
        self.recordingID = -1
        self.title = note.title
        self.startedAt = note.createdAt
        self.wavPath = note.fileURL.path
        self.txtPath = nil
        self.jsonPath = nil
        self.noteID = note.id
        self.notePath = note.fileURL.path
    }

    public init(
        kind: ContextSourceKind,
        sourceID: String,
        title: String,
        path: String,
        startedAt: Date = Date()
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.recordingID = -1
        self.title = title
        self.startedAt = startedAt
        self.wavPath = path
        self.txtPath = nil
        self.jsonPath = nil
        self.noteID = kind == .wikiPage ? sourceID : nil
        self.notePath = path
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
        var seen: Set<String> = []
        var ordered: [ContextSource] = []
        for block in blocks where !seen.contains(block.source.id) {
            seen.insert(block.source.id)
            ordered.append(block.source)
        }
        return ordered
    }

    public var isEmpty: Bool { blocks.isEmpty }

    public var approvedKnowledge: [ContextBlock] {
        blocks.filter { $0.kind == .synthesis && $0.source.kind == .wikiPage }
    }

    public var supportingEvidence: [ContextBlock] {
        blocks.filter { !($0.kind == .synthesis && $0.source.kind == .wikiPage) }
    }
}
