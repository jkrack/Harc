import Foundation

/// `harc://` deep-link router. Pure parsing — resolution of mode references
/// (id or case-insensitive name) against the live mode list happens at the
/// call site so this stays unit-testable.
///
/// Supported links:
/// - `harc://dictate` — start dictation with the active mode
/// - `harc://dictate?mode=<id-or-name>` — start dictation with a one-shot mode
/// - `harc://mode/<id-or-name>` — switch the active mode
/// - `harc://history` — open the dictation history window
public enum DictationDeepLink: Equatable, Sendable {
    case dictate(modeRef: String?)
    case switchMode(modeRef: String)
    case openHistory

    public static let scheme = "harc"

    public static func parse(_ url: URL) -> DictationDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // In `harc://dictate`, "dictate" is the host; path segments follow.
        let host = url.host?.lowercased() ?? ""
        switch host {
        case "dictate":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let modeRef = components?.queryItems?
                .first { $0.name.lowercased() == "mode" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .dictate(modeRef: modeRef?.isEmpty == false ? modeRef : nil)
        case "mode":
            let ref = url.pathComponents.drop(while: { $0 == "/" }).joined(separator: "/")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ref.isEmpty else { return nil }
            return .switchMode(modeRef: ref)
        case "history":
            return .openHistory
        default:
            return nil
        }
    }

    /// Resolve a mode reference against a mode list: exact id first, then
    /// case-insensitive name.
    public static func resolveMode(_ ref: String, in modes: [DictationMode]) -> DictationMode? {
        if let byID = modes.first(where: { $0.id == ref }) { return byID }
        let lowered = ref.lowercased()
        return modes.first { $0.name.lowercased() == lowered }
    }
}
