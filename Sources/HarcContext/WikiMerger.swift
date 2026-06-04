import CryptoKit
import Foundation

public struct WikiMergeResult: Sendable, Equatable {
    public var page: WikiPage
    public var didChange: Bool

    public init(page: WikiPage, didChange: Bool) {
        self.page = page
        self.didChange = didChange
    }
}

public actor WikiMerger {
    private let wikiStore: HarcWikiStore

    public init(wikiStore: HarcWikiStore = HarcWikiStore()) {
        self.wikiStore = wikiStore
    }

    @discardableResult
    public func merge(_ proposal: WikiReviewProposal) async throws -> WikiMergeResult {
        let pageID = "\(proposal.targetSection.rawValue)/\(HarcWikiStore.slug(proposal.targetTitle))"
        let existing = try await wikiStore.fetchPage(id: pageID)
        let mergedBody = Self.mergedBody(existingBody: existing?.body, proposal: proposal)

        guard existing?.body != mergedBody else {
            guard let existing else {
                let page = try await wikiStore.writePage(
                    section: proposal.targetSection,
                    title: proposal.targetTitle,
                    body: mergedBody
                )
                return WikiMergeResult(page: page, didChange: true)
            }
            return WikiMergeResult(page: existing, didChange: false)
        }

        let page = try await wikiStore.writePage(
            section: proposal.targetSection,
            title: proposal.targetTitle,
            body: mergedBody
        )
        return WikiMergeResult(page: page, didChange: true)
    }

    static func mergedBody(existingBody: String?, proposal: WikiReviewProposal) -> String {
        let proposedContent = contentWithoutTopLevelTitle(proposal.proposedMarkdown)
        let block = managedBlock(for: proposal, content: proposedContent)

        guard let existingBody, !existingBody.isEmpty else {
            let body = """
            ---
            title: \(proposal.targetTitle)
            section: \(proposal.targetSection.rawValue)
            sources:
            \(sourceLines(proposal.sourceCitations))
            ---

            # \(proposal.targetTitle)

            \(block)
            """
            return body.withTrailingNewline()
        }

        let withSources = mergeFrontMatterSources(
            in: existingBody,
            title: proposal.targetTitle,
            section: proposal.targetSection,
            sources: proposal.sourceCitations
        )

        if let range = managedBlockRange(id: proposal.id, in: withSources) {
            var next = withSources
            next.replaceSubrange(range, with: block)
            return next.withTrailingNewline()
        }

        if managedBlocks(in: withSources).contains(where: { normalizedMarkdown($0.content) == normalizedMarkdown(proposedContent) }) {
            return withSources.withTrailingNewline()
        }

        return appendManagedBlock(block, to: withSources).withTrailingNewline()
    }

    private static func managedBlock(for proposal: WikiReviewProposal, content: String) -> String {
        let digest = contentDigest(content)
        return """
        <!-- harc:managed:start id="\(proposal.id)" digest="\(digest)" -->
        \(content.trimmingCharacters(in: .whitespacesAndNewlines))
        <!-- harc:managed:end -->
        """
    }

    private static func appendManagedBlock(_ block: String, to body: String) -> String {
        var next = body.trimmingCharacters(in: .newlines)
        if !next.contains("\n## Updates\n") {
            next += "\n\n## Updates"
        }
        next += "\n\n\(block)"
        return next
    }

    private static func contentWithoutTopLevelTitle(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let firstContent = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstContent].hasPrefix("# ") {
            lines.remove(at: firstContent)
            while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeFrontMatterSources(
        in body: String,
        title: String,
        section: WikiSection,
        sources: [String]
    ) -> String {
        let uniqueSources = deduplicated(sources)
        guard !uniqueSources.isEmpty else { return body }

        guard let frontMatter = frontMatterRange(in: body) else {
            let frontMatter = """
            ---
            title: \(title)
            section: \(section.rawValue)
            sources:
            \(sourceLines(uniqueSources))
            ---

            """
            return frontMatter + body
        }

        let header = String(body[frontMatter.content])
        let mergedSources = deduplicated(existingSources(in: header) + uniqueSources)
        let updatedHeader = replacingSources(in: header, with: mergedSources)
        var next = body
        next.replaceSubrange(frontMatter.content, with: updatedHeader)
        return next
    }

    private static func replacingSources(in header: String, with sources: [String]) -> String {
        var lines = header.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "sources:" }) {
            var end = index + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") || trimmed.isEmpty {
                    end += 1
                } else {
                    break
                }
            }
            lines.replaceSubrange(index..<end, with: ["sources:"] + sourceLinesArray(sources))
        } else {
            if lines.last?.isEmpty == true {
                _ = lines.popLast()
            }
            lines.append("sources:")
            lines.append(contentsOf: sourceLinesArray(sources))
        }
        return lines.joined(separator: "\n")
    }

    private static func existingSources(in header: String) -> [String] {
        let lines = header.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "sources:" }) else {
            return []
        }
        var result: [String] = []
        for line in lines[(index + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                result.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            } else if !trimmed.isEmpty {
                break
            }
        }
        return result
    }

    private static func sourceLines(_ sources: [String]) -> String {
        sourceLinesArray(deduplicated(sources)).joined(separator: "\n")
    }

    private static func sourceLinesArray(_ sources: [String]) -> [String] {
        sources.map { "  - \($0)" }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func contentDigest(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedMarkdown(content).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedMarkdown(_ markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func frontMatterRange(in body: String) -> (full: Range<String.Index>, content: Range<String.Index>)? {
        guard body.hasPrefix("---\n"),
              let endStart = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex)
        else {
            return nil
        }
        let contentStart = body.index(body.startIndex, offsetBy: 4)
        let fullEnd = body.index(endStart.upperBound, offsetBy: 0)
        return (body.startIndex..<fullEnd, contentStart..<endStart.lowerBound)
    }

    private static func managedBlockRange(id: String, in body: String) -> Range<String.Index>? {
        let startNeedle = "<!-- harc:managed:start id=\"\(id)\""
        guard let start = body.range(of: startNeedle),
              let markerEnd = body.range(of: "-->", range: start.lowerBound..<body.endIndex),
              let end = body.range(of: "<!-- harc:managed:end -->", range: markerEnd.upperBound..<body.endIndex)
        else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }

    private static func managedBlocks(in body: String) -> [(id: String, content: String)] {
        var result: [(id: String, content: String)] = []
        var searchStart = body.startIndex
        while let start = body.range(of: "<!-- harc:managed:start", range: searchStart..<body.endIndex),
              let markerEnd = body.range(of: "-->", range: start.upperBound..<body.endIndex),
              let end = body.range(of: "<!-- harc:managed:end -->", range: markerEnd.upperBound..<body.endIndex) {
            let marker = String(body[start.lowerBound..<markerEnd.upperBound])
            let id = markerID(marker) ?? ""
            let content = String(body[markerEnd.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((id: id, content: content))
            searchStart = end.upperBound
        }
        return result
    }

    private static func markerID(_ marker: String) -> String? {
        guard let prefix = marker.range(of: "id=\"") else { return nil }
        let start = prefix.upperBound
        guard let end = marker[start...].firstIndex(of: "\"") else { return nil }
        return String(marker[start..<end])
    }
}

private extension String {
    func withTrailingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }
}
