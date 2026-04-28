import SwiftUI
import HarcStore

/// An inspector `Section` that wraps `SpeakerNameEditor` for use in the new
/// HarcWindowRootView's `.inspector` panel. Mirrors the inline speaker block
/// in `TranscriptionDetailView` (which is still live — duplication clears in
/// Task 3.5).
///
/// The caller is responsible for supplying `speakerIndices` (derived from the
/// JSON sidecar via `ExportInputBuilder`) and the `suggestionsProvider` closure
/// bridging to `SpeakerReIDService`. Both are optional: when `speakerIndices`
/// is empty or `nil`, `SpeakerNameEditor` renders nothing.
public struct SpeakerInspectorSection: View {
    private let speakerIndices: [Int]
    private let initialNames: [Int: String]
    private let onCommit: ([Int: String]) -> Void
    private let suggestionsProvider: SpeakerNameEditor.SuggestionsProvider?

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        self.speakerIndices = speakerIndices
        self.initialNames = initialNames
        self.onCommit = onCommit
        self.suggestionsProvider = suggestionsProvider
    }

    public var body: some View {
        Section {
            SpeakerNameEditor(
                speakerIndices: speakerIndices,
                initialNames: initialNames,
                onCommit: onCommit,
                suggestionsProvider: suggestionsProvider,
                showsHeader: false
            )
        } header: {
            Text("Speakers")
        }
    }
}
