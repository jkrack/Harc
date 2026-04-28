import SwiftUI
import HarcStore
import HarcExport

/// Inline editor showing one row per distinct speaker index present in
/// the recording. Users type display names; commits fire on Enter or
/// focus-loss via the `onCommit` callback. Visibility: the view renders
/// nothing when `speakerIndices` is empty (un-diarized recording).
///
/// When a `suggestionsProvider` is supplied, the editor also renders one
/// tappable chip per match below each speaker row — "Sounds like Jason ·
/// N prior recordings". Tapping fills the field + commits. Suggestions
/// come from `SpeakerReIDService` living above this view.
public struct SpeakerNameEditor: View {
    /// Closure that returns the top matches for a given speaker index. Called
    /// per row on appear; results cached in view state. The closure is
    /// async to bridge to `SpeakerReIDService`, which is actor-isolated.
    public typealias SuggestionsProvider = @Sendable (_ speakerIndex: Int) async -> [SpeakerSuggestion]

    private let speakerIndices: [Int]           // ascending, distinct
    private let initialNames: [Int: String]
    private let onCommit: ([Int: String]) -> Void
    private let suggestionsProvider: SuggestionsProvider?
    private let showsHeader: Bool

    @State private var draftNames: [Int: String]
    @State private var suggestions: [Int: [SpeakerSuggestion]] = [:]
    /// Chips the user has ×-dismissed for this speaker in this session.
    @State private var dismissedSuggestionIDs: [Int: Set<String>] = [:]

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void,
        suggestionsProvider: SuggestionsProvider? = nil,
        showsHeader: Bool = true
    ) {
        self.speakerIndices = speakerIndices.sorted()
        self.initialNames = initialNames
        self.onCommit = onCommit
        self.suggestionsProvider = suggestionsProvider
        self.showsHeader = showsHeader
        self._draftNames = State(initialValue: initialNames)
    }

    public var body: some View {
        if speakerIndices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if showsHeader {
                    Text("SPEAKERS")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .tracking(1.2)
                }
                ForEach(speakerIndices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        row(for: index)
                        if let provider = suggestionsProvider {
                            suggestionChips(for: index, provider: provider)
                        }
                    }
                }
            }
        }
    }

    private func row(for index: Int) -> some View {
        HStack(spacing: 12) {
            Text("Speaker \(index + 1)")
                .font(.body)
                .foregroundStyle(Color.primary)
                .frame(width: 90, alignment: .leading)
            TextField("Name (e.g. Jason)", text: binding(for: index))
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focusable(false)
                .onSubmit { commit() }
        }
    }

    @ViewBuilder
    private func suggestionChips(for index: Int, provider: SuggestionsProvider) -> some View {
        let raw = suggestions[index] ?? []
        let dismissed = dismissedSuggestionIDs[index] ?? []
        let visible = raw.filter { !dismissed.contains($0.id) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visible) { s in
                    SpeakerSuggestionChip(
                        suggestion: s,
                        onAccept: { acceptSuggestion(s, for: index) },
                        onDismiss: { dismissSuggestion(s, for: index) }
                    )
                }
            }
            .padding(.leading, 98) // align with TextField left edge
        }
        // Fetch once on appear. `provider` is captured on the init — the
        // view holds it as a stored property, so we can re-reference it
        // here in an escaping closure safely.
        Color.clear
            .frame(height: 0)
            .task(id: "\(index)-load") {
                guard suggestions[index] == nil else { return }
                guard let fn = suggestionsProvider else { return }
                let fetched = await fn(index)
                await MainActor.run { suggestions[index] = fetched }
            }
    }

    private func acceptSuggestion(_ s: SpeakerSuggestion, for index: Int) {
        guard let name = s.name, !name.isEmpty else { return }
        draftNames[index] = name
        commit()
    }

    private func dismissSuggestion(_ s: SpeakerSuggestion, for index: Int) {
        dismissedSuggestionIDs[index, default: []].insert(s.id)
    }

    /// Two-way binding into the `draftNames` dict. Reads return "" when
    /// the index has no entry so the TextField shows empty. Writes store
    /// the raw string; trimming happens at commit time.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { draftNames[index] ?? "" },
            set: { newValue in
                draftNames[index] = newValue
            }
        )
    }

    /// Normalise draftNames (trim, drop empty), compare against
    /// initialNames, fire callback only if changed.
    private func commit() {
        var normalised: [Int: String] = [:]
        for (k, v) in draftNames {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { normalised[k] = trimmed }
        }
        if normalised != initialNames {
            onCommit(normalised)
        }
    }
}
