import Foundation
import Combine

/// What the dictation HUD panel should render — a pure mapping from
/// (phase, persistent-pill pref, temporary hide, meeting-recording state)
/// so the show/hide policy is unit-testable without AppKit.
public enum DictationHUDPresentation: Equatable, Sendable {
    /// Panel ordered out.
    case hidden
    /// Dimmed compact pill while dictation is idle (persistent pref on).
    /// `recording` tints the pill and disables start — the mic belongs to
    /// the meeting recording.
    case idlePill(recording: Bool)
    /// The full live HUD (any active dictation phase, end states, errors).
    case live
    /// A harc://dictate link is awaiting user confirmation — the panel shows
    /// Start/Cancel and the mic stays closed until Start.
    case confirmDeepLink

    public static func from(
        phase: DictationState.Phase,
        persistent: Bool,
        temporarilyHidden: Bool,
        isRecording: Bool,
        pendingDeepLink: Bool = false
    ) -> DictationHUDPresentation {
        switch phase {
        case .idle:
            if pendingDeepLink { return .confirmDeepLink }
            guard persistent, !temporarilyHidden else { return .hidden }
            return .idlePill(recording: isRecording)
        default:
            return .live
        }
    }
}

/// Observable holder the panel's root view watches to switch between the
/// live HUD and the idle pill. Owned by AppDelegate, which recomputes the
/// presentation whenever phase / pref / recording state change.
@MainActor
public final class DictationHUDPresentationModel: ObservableObject {
    @Published public var presentation: DictationHUDPresentation = .hidden
    /// Hover state of the idle pill — published so the hosting panel can
    /// re-fit its size when controls reveal.
    @Published public var pillHovered: Bool = false

    public init() {}
}
