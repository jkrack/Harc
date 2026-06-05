import CryptoKit
import Foundation
import HarcStore

public enum LibraryReviewProposalGenerator {
    public static func proposals(
        recordings: [Recording],
        notes: [Note],
        maxRecordings: Int = 12,
        maxNotes: Int = 20,
        generatedAt: Date = Date()
    ) -> [WikiReviewProposal] {
        var proposals: [WikiReviewProposal] = []

        for recording in recordings
            .filter({ $0.summaryMarkdown?.trimmedNonEmpty != nil })
            .sorted(by: { $0.startedAt > $1.startedAt })
            .prefix(maxRecordings) {
            proposals.append(contentsOf: recordingProposals(for: recording, generatedAt: generatedAt))
        }

        for note in notes
            .filter({ !$0.archived && $0.body.trimmedNonEmpty != nil })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(maxNotes) {
            proposals.append(contentsOf: noteProposals(for: note, generatedAt: generatedAt))
        }

        return proposals
    }

    public static func recordingProposals(
        for recording: Recording,
        generatedAt: Date = Date()
    ) -> [WikiReviewProposal] {
        guard let summary = recording.summaryMarkdown?.trimmedNonEmpty else { return [] }
        let title = recording.displayTitle
        let hash = contentHash(["recording", stableRecordingID(recording), title, summary, recording.actionItemsMarkdown ?? ""])
        let citation = recordingCitation(recording, contentHash: hash)
        let source = citation.displayText
        var proposals: [WikiReviewProposal] = []

        let decisionLines = evidenceLines(in: summary, keywords: decisionKeywords)
        if !decisionLines.isEmpty {
            let targetTitle = "\(title) Decisions"
            proposals.append(WikiReviewProposal(
                id: proposalID(prefix: "recording-decisions", title: targetTitle, hash: hash),
                kind: .createPage,
                impact: .high,
                confidence: .medium,
                title: "Create decisions page: \(title)",
                summary: "Capture candidate decisions from the completed summary.",
                targetSection: .decisions,
                targetTitle: targetTitle,
                proposedMarkdown: """
                # \(targetTitle)

                Recording: \(title)

                ## Candidate Decisions

                \(decisionLines.prefix(12).map { "- \($0)" }.joined(separator: "\n"))

                ## Source Summary

                \(summary)
                """,
                sourceCitations: [source],
                knowledgeCitations: [citation],
                createdAt: generatedAt,
                updatedAt: generatedAt
            ))
        }

        let questionLines = evidenceLines(in: [summary, recording.actionItemsMarkdown ?? ""].joined(separator: "\n"), keywords: questionKeywords, includeQuestionMarks: true)
        if !questionLines.isEmpty {
            let targetTitle = "\(title) Open Questions"
            proposals.append(WikiReviewProposal(
                id: proposalID(prefix: "recording-open-questions", title: targetTitle, hash: hash),
                kind: .createPage,
                impact: .medium,
                confidence: .medium,
                title: "Create open questions page: \(title)",
                summary: "Capture unresolved questions and follow-ups from the completed summary.",
                targetSection: .openQuestions,
                targetTitle: targetTitle,
                proposedMarkdown: """
                # \(targetTitle)

                Recording: \(title)

                ## Candidate Open Questions

                \(questionLines.prefix(12).map { "- \($0)" }.joined(separator: "\n"))

                ## Source Summary

                \(summary)
                """,
                sourceCitations: [source],
                knowledgeCitations: [citation],
                createdAt: generatedAt,
                updatedAt: generatedAt
            ))
        }

        for project in projectNames(tags: recording.tags, body: summary).prefix(6) {
            let targetTitle = project
            proposals.append(WikiReviewProposal(
                id: proposalID(prefix: "recording-project", title: targetTitle, hash: hash),
                kind: .createPage,
                impact: .medium,
                confidence: .medium,
                title: "Update project page: \(project)",
                summary: "Add completed recording context to the project page.",
                targetSection: .projects,
                targetTitle: targetTitle,
                proposedMarkdown: """
                # \(targetTitle)

                ## Recording Context

                - \(title): \(compactSummary(summary))
                """,
                sourceCitations: [source],
                knowledgeCitations: [citation],
                createdAt: generatedAt,
                updatedAt: generatedAt
            ))
        }

        for person in personNames(recording: recording, text: summary).prefix(8) {
            proposals.append(personProposal(
                person: person,
                sourceTitle: title,
                sourceSummary: compactSummary(summary),
                sourceCitation: source,
                citation: citation,
                hash: hash,
                prefix: "recording-person",
                generatedAt: generatedAt
            ))
        }

        return proposals
    }

    public static func noteProposals(
        for note: Note,
        generatedAt: Date = Date()
    ) -> [WikiReviewProposal] {
        guard let body = note.body.trimmedNonEmpty else { return [] }
        let hash = contentHash(["note", note.id, note.title, body, note.tags.joined(separator: ","), note.people.joined(separator: ",")])
        let citation = noteCitation(note, contentHash: hash)
        let source = citation.displayText
        var proposals: [WikiReviewProposal] = []

        for project in projectNames(tags: note.tags, body: body).prefix(6) {
            proposals.append(WikiReviewProposal(
                id: proposalID(prefix: "note-project", title: project, hash: hash),
                kind: .createPage,
                impact: .medium,
                confidence: .high,
                title: "Update project page: \(project)",
                summary: "Add saved-note context to the project page.",
                targetSection: .projects,
                targetTitle: project,
                proposedMarkdown: """
                # \(project)

                ## Note Context

                - \(note.title): \(compactSummary(body))
                """,
                sourceCitations: [source],
                knowledgeCitations: [citation],
                createdAt: generatedAt,
                updatedAt: generatedAt
            ))
        }

        for person in personNames(note: note).prefix(8) {
            proposals.append(personProposal(
                person: person,
                sourceTitle: note.title,
                sourceSummary: compactSummary(body),
                sourceCitation: source,
                citation: citation,
                hash: hash,
                prefix: "note-person",
                generatedAt: generatedAt
            ))
        }

        for topic in topicNames(note: note).prefix(8) {
            proposals.append(WikiReviewProposal(
                id: proposalID(prefix: "note-topic", title: topic, hash: hash),
                kind: .createPage,
                impact: .low,
                confidence: .high,
                title: "Update topic page: \(topic)",
                summary: "Add saved-note context to the topic page.",
                targetSection: .topics,
                targetTitle: topic,
                proposedMarkdown: """
                # \(topic)

                ## Note Context

                - \(note.title): \(compactSummary(body))
                """,
                sourceCitations: [source],
                knowledgeCitations: [citation],
                createdAt: generatedAt,
                updatedAt: generatedAt
            ))
        }

        return proposals
    }

    private static func personProposal(
        person: String,
        sourceTitle: String,
        sourceSummary: String,
        sourceCitation: String,
        citation: KnowledgeCitation,
        hash: String,
        prefix: String,
        generatedAt: Date
    ) -> WikiReviewProposal {
        WikiReviewProposal(
            id: proposalID(prefix: prefix, title: person, hash: hash),
            kind: .createPage,
            impact: .medium,
            confidence: .medium,
            title: "Update person page: \(person)",
            summary: "Add reviewable context connected to \(person).",
            targetSection: .people,
            targetTitle: person,
            proposedMarkdown: """
            # \(person)

            ## Recent Context

            - \(sourceTitle): \(sourceSummary)
            """,
            sourceCitations: [sourceCitation],
            knowledgeCitations: [citation],
            createdAt: generatedAt,
            updatedAt: generatedAt
        )
    }

    private static let decisionKeywords = ["decided", "decision", "agreed", "approved", "accepted", "rejected", "chose", "committed"]
    private static let questionKeywords = ["todo", "follow up", "follow-up", "question", "open question", "blocked", "needs", "next step", "action item"]

    private static func evidenceLines(in text: String, keywords: [String], includeQuestionMarks: Bool = false) -> [String] {
        unique(
            text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*"))) }
                .filter { line in
                    guard !line.isEmpty else { return false }
                    let lower = line.lowercased()
                    return keywords.contains { lower.contains($0) } || (includeQuestionMarks && line.contains("?"))
                }
        )
    }

    private static func projectNames(tags: [String], body: String) -> [String] {
        var names = tags.compactMap { tag -> String? in
            guard tag.lowercased().hasPrefix("project:") else { return nil }
            return String(tag.dropFirst("project:".count))
        }
        names.append(contentsOf: regexMatches(#"@project\[([^\]\n]+)\]"#, in: body))
        return uniqueLabels(names)
    }

    private static func personNames(recording: Recording, text: String) -> [String] {
        uniqueLabels(Array(recording.speakerNames.values) + regexMatches(#"@person\[([^\]\n]+)\]|@\[([^\]\n]+)\]"#, in: text))
    }

    private static func personNames(note: Note) -> [String] {
        uniqueLabels(note.people + regexMatches(#"@person\[([^\]\n]+)\]|@\[([^\]\n]+)\]"#, in: note.body))
    }

    private static func topicNames(note: Note) -> [String] {
        let explicitTags = note.tags.filter { !$0.lowercased().hasPrefix("project:") }
        let wikiLinks = regexMatches(#"\[\[([^\]\n]+)\]\]"#, in: note.body)
        return uniqueLabels(explicitTags + wikiLinks)
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            for index in 1..<match.numberOfRanges {
                guard let swiftRange = Range(match.range(at: index), in: text) else { continue }
                let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return nil
        }
    }

    private static func uniqueLabels(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = HarcWikiStore.slug(trimmed)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func unique(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func compactSummary(_ markdown: String) -> String {
        let text = markdown
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#-*`"))) }
            .first(where: { !$0.isEmpty }) ?? markdown
        return String(text.prefix(180))
    }

    private static func recordingCitation(_ recording: Recording, contentHash: String) -> KnowledgeCitation {
        KnowledgeCitation(
            id: "recording:\(stableRecordingID(recording)):\(contentHash)",
            kind: .recording,
            title: recording.displayTitle,
            path: recording.wavPath,
            contentHash: contentHash
        )
    }

    private static func noteCitation(_ note: Note, contentHash: String) -> KnowledgeCitation {
        KnowledgeCitation(
            id: "note:\(note.id):\(contentHash)",
            kind: .note,
            title: note.title,
            path: note.fileURL.path,
            contentHash: contentHash
        )
    }

    private static func stableRecordingID(_ recording: Recording) -> String {
        recording.id.map(String.init) ?? recording.wavPath
    }

    private static func proposalID(prefix: String, title: String, hash: String) -> String {
        "\(prefix)-\(HarcWikiStore.slug(title))-\(hash.prefix(16))"
    }

    private static func contentHash(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
