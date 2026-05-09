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

        appendSection(.directEvidence, title: "Relevant Evidence", from: pack, into: &lines)
        appendSection(.summary, title: "Summaries", from: pack, into: &lines)
        appendSection(.actionItems, title: "Action Items", from: pack, into: &lines)

        lines.append("## Sources")
        for source in pack.sources {
            lines.append("- \(source.title) - \(source.wavPath)")
        }

        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        _ kind: ContextBlockKind,
        title: String,
        from pack: ContextPack,
        into lines: inout [String]
    ) {
        let blocks = pack.blocks.filter { $0.kind == kind }
        guard !blocks.isEmpty else { return }

        lines.append("## \(title)")
        for block in blocks {
            lines.append("")
            lines.append("### \(block.source.title)")
            lines.append(block.text)
        }
        lines.append("")
    }
}
