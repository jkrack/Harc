import Foundation

/// Current state of a model on disk. Single source of truth consumed by the
/// Settings UI, feature gating views (`ModelRequirementView`), and any code
/// that needs to know whether to fire its feature or prompt the user.
///
/// State transitions are documented in the design doc
/// (`docs/superpowers/specs/2026-04-22-model-manager-design.md` §4.1).
public enum ModelInstallState: Equatable, Sendable {
    /// Not installed, nothing in progress.
    case absent
    /// Download in flight. `progress` is bytes done / total bytes.
    case downloading(progress: Double)
    /// All files present; computing SHA256 against the manifest.
    case verifying
    /// Installed and verified. Ready to use.
    case installed
    /// Something went wrong. `reason` is user-readable.
    case failed(reason: String)
}

public extension ModelInstallState {
    /// True when the model is fully present and trusted — the one gate that
    /// features check before firing.
    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// True while the state machine is actively mutating. UI rows should show
    /// spinners / progress and disable interaction.
    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: return true
        default: return false
        }
    }
}
