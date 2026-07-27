import Foundation

/// The 4pt spacing scale.
///
/// Values in the codebase ran 1,2,3,4,5,6,7,8,10,12,14,16,20 — two adjacent
/// stacks in one view used 7 and 8, and nothing depended on the difference.
/// Six steps; if a layout seems to need a value between two of them, the
/// layout is the thing to question.
public enum HarcSpacing {
    /// Hairline relationships: icon-to-label, dot-to-text.
    public static let xs: CGFloat = 4
    /// Within a group: rows of the same list, label-to-value.
    public static let sm: CGFloat = 8
    /// Between related groups.
    public static let md: CGFloat = 12
    /// Between sections.
    public static let lg: CGFloat = 16
    /// Pane padding, major separations.
    public static let xl: CGFloat = 24
    /// Hero spacing — welcome pages, empty states.
    public static let xxl: CGFloat = 32
}
