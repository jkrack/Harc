import Foundation

// Supporting value types for `HarcWindowRootView`. Extracted from the view
// file to keep that file focused on view code. These were `private` to the
// view file; they are `internal` here and used only within HarcUI.

// MARK: - LibrarySelection

/// Discriminated union for the sidebar selection. A recording (keyed by wav
/// path), a Person row (keyed by DB id), a session (keyed by DB id), or the
/// in-progress recording.
public enum LibrarySelection: Hashable {
    /// The recording happening right now. At most one exists, it has no wav
    /// path until it finishes, and it must never be persisted — recordings do
    /// not span launches, so restoring it would select a ghost.
    case live
    case recording(wavPath: String)
    case person(id: Int64)
    case session(id: Int64)
}
