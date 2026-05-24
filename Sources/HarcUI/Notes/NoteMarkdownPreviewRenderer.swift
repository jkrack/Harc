import Foundation

enum NoteMarkdownPreviewRenderer {
    enum BlockKind: Equatable {
        case heading(level: Int)
        case paragraph
        case unorderedListItem
        case orderedListItem(number: Int)
        case quote
        case thematicBreak
        case code
    }

    struct Block: Equatable {
        var kind: BlockKind
        var content: AttributedString

        var visibleText: String {
            String(content.characters)
        }
    }

    static func rendered(_ markdown: String) -> AttributedString {
        let normalized = markdownWithLenientHeadingSpacing(markdown)
        if let rendered = try? AttributedString(
            markdown: normalized,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return rendered
        }
        return AttributedString(markdown)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(Block(kind: .paragraph, content: renderedInline(paragraphLines.joined(separator: "\n"))))
            paragraphLines.removeAll()
        }

        for line in markdownWithLenientHeadingSpacing(markdown).components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(Block(kind: .code, content: AttributedString(codeLines.joined(separator: "\n"))))
                    codeLines.removeAll()
                } else {
                    flushParagraph()
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .heading(level: heading.level), content: renderedInline(heading.text)))
            } else if let item = parseUnorderedListItem(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .unorderedListItem, content: renderedInline(item)))
            } else if let ordered = parseOrderedListItem(trimmed) {
                flushParagraph()
                blocks.append(Block(kind: .orderedListItem(number: ordered.number), content: renderedInline(ordered.text)))
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(Block(kind: .thematicBreak, content: AttributedString("")))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .quote, content: renderedInline(quote)))
            } else {
                paragraphLines.append(line)
            }
        }

        if inCodeBlock {
            blocks.append(Block(kind: .code, content: AttributedString(codeLines.joined(separator: "\n"))))
        }
        flushParagraph()
        return blocks
    }

    static func markdownWithLenientHeadingSpacing(_ markdown: String) -> String {
        let pattern = #"(?m)^(#{1,6})([^\s#].*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdown
        }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: "$1 $2"
        )
    }

    private static func renderedInline(_ markdown: String) -> AttributedString {
        if let rendered = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return rendered
        }
        return AttributedString(markdown)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) else { return nil }
        return (match.output.1.count, String(match.output.2))
    }

    private static func parseUnorderedListItem(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^[-*]\s+(.+)$/) else { return nil }
        return String(match.output.1)
    }

    private static func parseOrderedListItem(_ line: String) -> (number: Int, text: String)? {
        guard let match = line.firstMatch(of: /^([0-9]+)[.)]\s+(.+)$/),
              let number = Int(match.output.1) else {
            return nil
        }
        return (number, String(match.output.2))
    }
}
