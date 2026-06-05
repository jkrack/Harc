import CryptoKit
import Foundation

public enum SourceWikiProposalGenerator {
    public static func proposals(
        for root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        maxDocuments: Int = 40,
        generatedAt: Date = Date()
    ) -> [WikiReviewProposal] {
        let selected = Array(documents.prefix(maxDocuments))
        guard !selected.isEmpty else { return [] }

        var proposals: [WikiReviewProposal] = [
            sourceOverviewProposal(root: root, documents: selected, generatedAt: generatedAt)
        ]

        if root.kind == .repository {
            proposals.append(projectMapProposal(root: root, documents: selected, generatedAt: generatedAt))
        }

        if let decisionProposal = decisionsProposal(root: root, documents: selected, generatedAt: generatedAt) {
            proposals.append(decisionProposal)
        }

        if let questionProposal = openQuestionsProposal(root: root, documents: selected, generatedAt: generatedAt) {
            proposals.append(questionProposal)
        }

        proposals.append(contentsOf: selected.prefix(10).map {
            sourceDocumentProposal(root: root, document: $0, generatedAt: generatedAt)
        })

        return proposals
    }

    private static func sourceOverviewProposal(
        root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        generatedAt: Date
    ) -> WikiReviewProposal {
        let counts = Dictionary(grouping: documents, by: { $0.provenance.documentKind })
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        let directories = topDirectories(in: documents)
        let title = "\(root.displayName) Source Overview"
        let body = """
        # \(title)

        Source root: \(root.displayName)
        Root path: \(root.path)
        Root kind: \(root.kind.rawValue)
        Documents scanned: \(documents.count)

        ## Content Types

        \(counts.map { "- \($0.key.rawValue): \($0.value)" }.joined(separator: "\n"))

        ## Main Areas

        \(directories.isEmpty ? "- Root-level files" : directories.map { "- \($0)" }.joined(separator: "\n"))

        ## Representative Files

        \(documents.prefix(12).map { "- `\($0.provenance.relativePath)` - \(compactSummary(for: $0))" }.joined(separator: "\n"))

        ## Sources

        \(documents.prefix(20).map { "- \($0.provenance.citationPath)" }.joined(separator: "\n"))
        """

        return WikiReviewProposal(
            id: proposalID(prefix: "source-overview", root: root, documents: documents, title: title),
            kind: .createPage,
            impact: .medium,
            confidence: .medium,
            title: "Create source overview: \(root.displayName)",
            summary: "Add a synthesized overview of \(root.displayName), grouped by content type and area.",
            targetSection: .sources,
            targetTitle: title,
            proposedMarkdown: body,
            sourceCitations: citations(from: documents, limit: 20),
            knowledgeCitations: knowledgeCitations(from: documents, limit: 20),
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static func projectMapProposal(
        root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        generatedAt: Date
    ) -> WikiReviewProposal {
        let title = "\(root.displayName) Project Map"
        let readmes = documents.filter { $0.provenance.relativePath.lowercased().contains("readme") }
        let docs = documents.filter { $0.provenance.relativePath.lowercased().hasPrefix("docs/") }
        let tests = documents.filter { $0.provenance.relativePath.lowercased().contains("test") }
        let sourceFiles = documents.filter { $0.provenance.documentKind == .sourceCode }

        let body = """
        # \(title)

        Repository: \(root.displayName)
        Root path: \(root.path)

        ## What This Repository Appears To Contain

        \(summaryBullets(for: readmes.isEmpty ? documents : readmes, limit: 5))

        ## Code Surface

        \(sourceFiles.prefix(12).map { "- `\($0.provenance.relativePath)` - \(compactSummary(for: $0))" }.joined(separator: "\n"))

        ## Documentation Surface

        \((readmes + docs).prefix(12).map { "- `\($0.provenance.relativePath)` - \(compactSummary(for: $0))" }.joined(separator: "\n"))

        ## Test Surface

        \(tests.prefix(12).map { "- `\($0.provenance.relativePath)` - \(compactSummary(for: $0))" }.joined(separator: "\n"))

        ## Sources

        \(citations(from: documents, limit: 20).map { "- \($0)" }.joined(separator: "\n"))
        """

        return WikiReviewProposal(
            id: proposalID(prefix: "project-map", root: root, documents: documents, title: title),
            kind: .createPage,
            impact: .high,
            confidence: .medium,
            title: "Create project map: \(root.displayName)",
            summary: "Add a synthesized project map for the repository structure, docs, code, and tests.",
            targetSection: .projects,
            targetTitle: title,
            proposedMarkdown: body,
            sourceCitations: citations(from: documents, limit: 20),
            knowledgeCitations: knowledgeCitations(from: documents, limit: 20),
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static func decisionsProposal(
        root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        generatedAt: Date
    ) -> WikiReviewProposal? {
        let matches = evidenceLines(
            in: documents,
            keywords: ["decided", "decision", "agreed", "approved", "adr", "accepted", "rejected"]
        )
        guard !matches.isEmpty else { return nil }
        let title = "\(root.displayName) Decisions"
        let body = """
        # \(title)

        These are candidate decisions found in scanned source material. Review before approval.

        ## Candidate Decisions

        \(matches.prefix(25).map { "- \($0.text) [\($0.citation)]" }.joined(separator: "\n"))
        """

        return WikiReviewProposal(
            id: proposalID(prefix: "decisions", root: root, documents: documents, title: title),
            kind: .createPage,
            impact: .high,
            confidence: .medium,
            title: "Create decisions page: \(root.displayName)",
            summary: "Capture candidate decisions found in \(root.displayName) source files.",
            targetSection: .decisions,
            targetTitle: title,
            proposedMarkdown: body,
            sourceCitations: Array(Set(matches.map(\.citation))).sorted(),
            knowledgeCitations: deduplicatedCitations(matches.map(\.knowledgeCitation)),
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static func openQuestionsProposal(
        root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        generatedAt: Date
    ) -> WikiReviewProposal? {
        let matches = evidenceLines(
            in: documents,
            keywords: ["todo", "fixme", "question", "unknown", "tbd", "follow up", "open question"],
            includeQuestionMarks: true
        )
        guard !matches.isEmpty else { return nil }
        let title = "\(root.displayName) Open Questions"
        let body = """
        # \(title)

        These are candidate open questions and follow-ups found in scanned source material. Review before approval.

        ## Candidate Open Questions

        \(matches.prefix(25).map { "- \($0.text) [\($0.citation)]" }.joined(separator: "\n"))
        """

        return WikiReviewProposal(
            id: proposalID(prefix: "open-questions", root: root, documents: documents, title: title),
            kind: .createPage,
            impact: .medium,
            confidence: .medium,
            title: "Create open questions page: \(root.displayName)",
            summary: "Capture candidate open questions and TODOs found in \(root.displayName).",
            targetSection: .openQuestions,
            targetTitle: title,
            proposedMarkdown: body,
            sourceCitations: Array(Set(matches.map(\.citation))).sorted(),
            knowledgeCitations: deduplicatedCitations(matches.map(\.knowledgeCitation)),
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static func sourceDocumentProposal(
        root: LocalSourceRoot,
        document: ScannedSourceDocument,
        generatedAt: Date
    ) -> WikiReviewProposal {
        let sourceKind = root.kind == .repository ? "repository" : "folder"
        let title = "\(document.title) Source Notes"
        let markdown = """
        # \(title)

        Source: \(document.provenance.relativePath)
        Root: \(root.displayName)
        Kind: \(sourceKind)
        Content hash: \(document.provenance.contentHash)

        ## What This File Appears To Contain

        \(summaryBullets(for: [document], limit: 6))

        ## Extract

        \(String(document.text.prefix(4_000)))
        """

        return WikiReviewProposal(
            id: "source-\(document.provenance.contentHash)-\(HarcWikiStore.slug(document.provenance.relativePath))",
            kind: .createPage,
            impact: .low,
            confidence: .high,
            title: "Create source notes: \(document.title)",
            summary: "Add reviewable notes for \(document.provenance.relativePath).",
            targetSection: .sources,
            targetTitle: title,
            proposedMarkdown: markdown,
            sourceCitations: [document.provenance.citationPath],
            knowledgeCitations: [KnowledgeCitation.sourceFile(from: document.provenance)],
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static func topDirectories(in documents: [ScannedSourceDocument]) -> [String] {
        let counts = Dictionary(grouping: documents) { document in
            document.provenance.relativePath.split(separator: "/").first.map(String.init) ?? ""
        }
        return counts
            .filter { !$0.key.isEmpty }
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.key < $1.key
            }
            .prefix(10)
            .map { "\($0.key) (\($0.value.count) files)" }
    }

    private static func summaryBullets(for documents: [ScannedSourceDocument], limit: Int) -> String {
        let bullets = documents
            .flatMap { meaningfulLines(from: $0.text).prefix(3) }
            .prefix(limit)
            .map { "- \($0)" }
        return bullets.isEmpty ? "- No readable summary lines found." : bullets.joined(separator: "\n")
    }

    private static func compactSummary(for document: ScannedSourceDocument) -> String {
        meaningfulLines(from: document.text).first ?? document.provenance.documentKind.rawValue
    }

    private static func meaningfulLines(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#/-*`"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { line in
                guard line.count >= 8 else { return false }
                let lowered = line.lowercased()
                return !lowered.hasPrefix("import ")
                    && !lowered.hasPrefix("package ")
                    && !lowered.hasPrefix("//")
                    && !lowered.hasPrefix("/*")
                    && !lowered.hasPrefix("*")
            }
            .map { String($0.prefix(220)) }
    }

    private struct EvidenceLine {
        var text: String
        var citation: String
        var knowledgeCitation: KnowledgeCitation
    }

    private static func evidenceLines(
        in documents: [ScannedSourceDocument],
        keywords: [String],
        includeQuestionMarks: Bool = false
    ) -> [EvidenceLine] {
        var results: [EvidenceLine] = []
        for document in documents {
            let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.count >= 8 else { continue }
                let lowered = line.lowercased()
                let keywordMatch = keywords.contains { lowered.contains($0) }
                guard keywordMatch || (includeQuestionMarks && line.contains("?")) else { continue }
                let lineNumber = index + 1
                results.append(EvidenceLine(
                    text: String(line.prefix(260)),
                    citation: "\(document.provenance.absolutePath):\(lineNumber)",
                    knowledgeCitation: .sourceFile(document: document, lineStart: lineNumber)
                ))
            }
        }
        return Array(results.prefix(50))
    }

    private static func citations(from documents: [ScannedSourceDocument], limit: Int) -> [String] {
        Array(documents.map(\.provenance.citationPath).prefix(limit))
    }

    private static func knowledgeCitations(from documents: [ScannedSourceDocument], limit: Int) -> [KnowledgeCitation] {
        deduplicatedCitations(documents.prefix(limit).map { .sourceFile(from: $0.provenance) })
    }

    private static func deduplicatedCitations(_ citations: [KnowledgeCitation]) -> [KnowledgeCitation] {
        var seen = Set<String>()
        var result: [KnowledgeCitation] = []
        for citation in citations {
            guard seen.insert(citation.id).inserted else { continue }
            result.append(citation)
        }
        return result
    }

    private static func proposalID(
        prefix: String,
        root: LocalSourceRoot,
        documents: [ScannedSourceDocument],
        title: String
    ) -> String {
        let input = ([root.id, root.path, title] + documents.map(\.provenance.contentHash)).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(input.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(prefix)-\(HarcWikiStore.slug(root.displayName))-\(hash)"
    }
}
