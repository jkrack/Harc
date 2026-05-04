import SwiftUI
import HarcStore

/// An inspector `Section` that wraps `SpeakerNameEditor` for use in
/// HarcWindowRootView's `.inspector` panel.
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

    // Task 8.1: pending suggestions
    private let pendingSuggestions: [PendingSuggestion]
    private let personNamesByID: [Int64: String]
    private let onConfirmSuggestion: (PendingSuggestion) -> Void
    private let onDismissSuggestion: (PendingSuggestion) -> Void

    // Task 8.2: People picker
    private let recordingID: Int64?
    private let allPeople: [Person]
    private let onLinkPerson: (_ personID: Int64, _ speakerIndex: Int) -> Void
    private let onCreatePerson: (_ displayName: String, _ speakerIndex: Int) -> Void
    private let onUnlinkPerson: (_ speakerIndex: Int) -> Void

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil,
        pendingSuggestions: [PendingSuggestion] = [],
        personNamesByID: [Int64: String] = [:],
        onConfirmSuggestion: @escaping (PendingSuggestion) -> Void = { _ in },
        onDismissSuggestion: @escaping (PendingSuggestion) -> Void = { _ in },
        recordingID: Int64? = nil,
        allPeople: [Person] = [],
        onLinkPerson: @escaping (_ personID: Int64, _ speakerIndex: Int) -> Void = { _, _ in },
        onCreatePerson: @escaping (_ displayName: String, _ speakerIndex: Int) -> Void = { _, _ in },
        onUnlinkPerson: @escaping (_ speakerIndex: Int) -> Void = { _ in }
    ) {
        self.speakerIndices = speakerIndices
        self.initialNames = initialNames
        self.onCommit = onCommit
        self.suggestionsProvider = suggestionsProvider
        self.pendingSuggestions = pendingSuggestions
        self.personNamesByID = personNamesByID
        self.onConfirmSuggestion = onConfirmSuggestion
        self.onDismissSuggestion = onDismissSuggestion
        self.recordingID = recordingID
        self.allPeople = allPeople
        self.onLinkPerson = onLinkPerson
        self.onCreatePerson = onCreatePerson
        self.onUnlinkPerson = onUnlinkPerson
    }

    public var body: some View {
        Section {
            SpeakerNameEditor(
                speakerIndices: speakerIndices,
                initialNames: initialNames,
                onCommit: onCommit,
                suggestionsProvider: suggestionsProvider,
                showsHeader: false,
                pendingSuggestions: pendingSuggestions,
                personNamesByID: personNamesByID,
                onConfirmSuggestion: onConfirmSuggestion,
                onDismissSuggestion: onDismissSuggestion,
                recordingID: recordingID,
                allPeople: allPeople,
                onLinkPerson: onLinkPerson,
                onCreatePerson: onCreatePerson,
                onUnlinkPerson: onUnlinkPerson
            )
        } header: {
            Text("Speakers")
        }
    }
}
