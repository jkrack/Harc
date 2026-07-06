import Foundation

// Supporting value types for `HarcWindowRootView`. Extracted from the view
// file to keep that file focused on view code. These were `private` to the
// view file; they are `internal` here and used only within HarcUI.

// MARK: - LibrarySelection

/// Discriminated union for the sidebar selection. Either a recording (keyed
/// by wav path) or a Person row (keyed by DB id).
public enum LibrarySelection: Hashable {
    case recording(wavPath: String)
    case person(id: Int64)
}
