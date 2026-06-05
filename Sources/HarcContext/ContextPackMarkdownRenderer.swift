import Foundation

public enum ContextPackMarkdownRenderer {
    public static func render(_ pack: ContextPack) -> String {
        var lines: [String] = [
            "# Context: \(pack.query)",
            "",
            "Intent: \(pack.intent.rawValue)",
            "Retrieval: \(pack.retrievalQueries.joined(separator: ", "))",
            "",
        ]

        if pack.blocks.isEmpty {
            lines.append("_No matching context found._")
            return lines.joined(separator: "\n")
        }

        appendApprovedKnowledge(from: pack, into: &lines)
        appendSection(.synthesis, title: "Other Synthesis", from: pack, into: &lines) {
            $0.source.kind != .wikiPage
        }
        appendSection(.directEvidence, title: "Supporting Evidence", from: pack, into: &lines)
        appendSection(.summary, title: "Supporting Summaries", from: pack, into: &lines)
        appendSection(.actionItems, title: "Action Items", from: pack, into: &lines)

        lines.append("## Sources")
        for source in pack.sources {
            switch source.kind {
            case .recording:
                lines.append("- Recording: \(source.title) - \(source.wavPath)")
            case .note:
                lines.append("- Note: \(source.title) - \(source.notePath ?? source.wavPath)")
            case .rawFile:
                lines.append("- Raw file: \(source.title) - \(source.notePath ?? source.wavPath)")
            case .repoFile:
                lines.append("- Repo file: \(source.title) - \(source.notePath ?? source.wavPath)")
            case .wikiPage:
                lines.append("- Wiki page: \(source.title) - \(source.notePath ?? source.wavPath)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        _ kind: ContextBlockKind,
        title: String,
        from pack: ContextPack,
        into lines: inout [String],
        where include: (ContextBlock) -> Bool = { _ in true }
    ) {
        let blocks = pack.blocks.filter { $0.kind == kind && include($0) }
        guard !blocks.isEmpty else { return }

        lines.append("## \(title)")
        for block in blocks {
            lines.append("")
            lines.append("### \(block.source.title)")
            lines.append(block.text)
        }
        lines.append("")
    }

    private static func appendApprovedKnowledge(from pack: ContextPack, into lines: inout [String]) {
        let blocks = pack.approvedKnowledge
        guard !blocks.isEmpty else { return }

        lines.append("## Approved Knowledge")
        for block in blocks {
            lines.append("")
            lines.append("### \(block.source.title)")
            lines.append(block.text)
        }
        lines.append("")
    }
}
