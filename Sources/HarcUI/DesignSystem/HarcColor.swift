import SwiftUI

/// What a status color is allowed to mean.
///
/// Warning was yellow in four files and orange in three; purple meant
/// pinned, indigo meant transforming, green meant ready — all chosen at the
/// call site. Five meanings, five colors, defined once. `NativeStatusCallout`
/// already speaks intent; this makes intent the only way a status color is
/// ever produced.
public enum HarcStatusIntent {
    /// Working as intended; requires nothing.
    case ready
    /// Busy on the user's behalf — progress, not a problem.
    case working
    /// Needs the user, not urgently — degraded, waiting, recoverable.
    case attention
    /// Broken until acted on.
    case failure
    /// Capture is live. Deliberately the brand red: the one state that
    /// justifies saturation.
    case live
}

public extension Color {
    static func harc(_ intent: HarcStatusIntent) -> Color {
        switch intent {
        case .ready: return .green
        case .working: return .accentColor
        case .attention: return .orange
        case .failure: return .red
        case .live: return HarcBrand.live
        }
    }
}
