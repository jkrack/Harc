import Foundation

/// Outcome of the auto-paste policy check. The caller inspects this to
/// decide whether to paste and, if not, which kind of skip happened —
/// which drives the menu-bar flash style.
public enum AutoPasteDecision: Equatable, Sendable {
    case paste
    case skipDisabled
    case skipModifierHeld
    case skipUnsafeTarget(bundleID: String)
}

/// Pure decision function for auto-paste-on-stop. Precedence:
///
/// 1. `!enabled`      → `.skipDisabled`
/// 2. `shiftHeld`     → `.skipModifierHeld` (user-initiated override)
/// 3. deny-list hit   → `.skipUnsafeTarget`
/// 4. otherwise       → `.paste`
///
/// See spec §3.1 for the full matrix.
public enum AutoPasteGuard {
    public static func decide(
        enabled: Bool,
        shiftHeld: Bool,
        frontmostBundleID: String?
    ) -> AutoPasteDecision {
        if !enabled { return .skipDisabled }
        if shiftHeld { return .skipModifierHeld }
        if let id = frontmostBundleID, PasteDenyList.isDenied(id) {
            return .skipUnsafeTarget(bundleID: id)
        }
        return .paste
    }
}
