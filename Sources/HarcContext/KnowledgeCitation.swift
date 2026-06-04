import Foundation

public enum KnowledgeCitationKind: String, Sendable, Codable, Equatable, CaseIterable {
    case recording
    case note
    case wikiPage
    case sourceFile
}

public struct KnowledgeCitation: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var kind: KnowledgeCitationKind
    public var title: String?
    public var path: String?
    public var lineStart: Int?
    public var lineEnd: Int?
    public var timestampSeconds: Double?
    public var contentHash: String?

    public init(
        id: String,
        kind: KnowledgeCitationKind,
        title: String? = nil,
        path: String? = nil,
        lineStart: Int? = nil,
        lineEnd: Int? = nil,
        timestampSeconds: Double? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.timestampSeconds = timestampSeconds
        self.contentHash = contentHash
    }

    public var displayText: String {
        switch kind {
        case .recording:
            return [title ?? "Recording", timestampLabel].compactMap { $0 }.joined(separator: " @ ")
        case .note:
            return title ?? path ?? id
        case .wikiPage:
            return title ?? id
        case .sourceFile:
            guard let path else { return title ?? id }
            if let lineStart, let lineEnd, lineEnd != lineStart {
                return "\(path):\(lineStart)-\(lineEnd)"
            }
            if let lineStart {
                return "\(path):\(lineStart)"
            }
            return path
        }
    }

    private var timestampLabel: String? {
        guard let timestampSeconds else { return nil }
        let totalSeconds = max(0, Int(timestampSeconds.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

public extension KnowledgeCitation {
    static func sourceFile(from provenance: SourceProvenance) -> KnowledgeCitation {
        KnowledgeCitation(
            id: "source-file:\(provenance.rootID):\(provenance.relativePath):\(provenance.contentHash)",
            kind: .sourceFile,
            title: provenance.relativePath,
            path: provenance.absolutePath,
            lineStart: provenance.lineStart,
            lineEnd: provenance.lineEnd,
            contentHash: provenance.contentHash
        )
    }

    static func sourceFile(
        document: ScannedSourceDocument,
        lineStart: Int,
        lineEnd: Int? = nil
    ) -> KnowledgeCitation {
        var citation = sourceFile(from: document.provenance)
        citation.id = "source-file:\(document.provenance.rootID):\(document.provenance.relativePath):\(lineStart)"
        citation.lineStart = lineStart
        citation.lineEnd = lineEnd ?? lineStart
        return citation
    }
}
