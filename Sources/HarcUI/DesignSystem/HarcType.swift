import SwiftUI

/// The type scale: five roles, chosen once.
///
/// Before this, eleven styles were picked per call site — `.caption` and
/// `.caption2` both served as secondary explanatory text in the same view,
/// and nothing could be reasoned about. A role answers "what is this text
/// doing", not "how big should it look today".
public extension Font {
    /// Section and window headings. Absorbs `.headline`, `.title3`, `.title2`.
    static let harcTitle: Font = .headline
    /// Reading text — transcripts, summaries, primary row labels.
    /// Absorbs `.body` and `.callout`.
    static let harcBody: Font = .body
    /// Control and row labels that sit beside body text without competing.
    /// Absorbs `.subheadline`.
    static let harcLabel: Font = .subheadline
    /// Secondary and explanatory text. Absorbs `.caption` and `.caption2` —
    /// the split between those two carried no meaning anywhere it appeared.
    static let harcCaption: Font = .caption
    /// Tabular facts: timers, counts, byte sizes, paths. The one monospaced
    /// role; sized to sit alongside `harcCaption`.
    static let harcMono: Font = .system(.caption, design: .monospaced)
}
