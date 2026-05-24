import Foundation

enum NoteMarkdownPreviewRenderer {
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
}
