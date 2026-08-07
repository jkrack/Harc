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

    // Task 8.1: pending suggestions from the store-backed system
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

    @State private var draftNames: [Int: String]
    @State private var suggestions: [Int: [SpeakerSuggestion]] = [:]
    /// Chips the user has ×-dismissed for this speaker in this session.
    @State private var dismissedSuggestionIDs: [Int: Set<String>] = [:]
    /// Non-nil when the "Add new person…" menu item was tapped.
    @State private var addingPersonForIndex: Int?

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void,
        suggestionsProvider: SuggestionsProvider? = nil,
        showsHeader: Bool = true,
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
        self.speakerIndices = speakerIndices.sorted()
        self.initialNames = initialNames
        self.onCommit = onCommit
        self.suggestionsProvider = suggestionsProvider
        self.showsHeader = showsHeader
        self.pendingSuggestions = pendingSuggestions
        self.personNamesByID = personNamesByID
        self.onConfirmSuggestion = onConfirmSuggestion
        self.onDismissSuggestion = onDismissSuggestion
        self.recordingID = recordingID
        self.allPeople = allPeople
        self.onLinkPerson = onLinkPerson
        self.onCreatePerson = onCreatePerson
        self.onUnlinkPerson = onUnlinkPerson
        self._draftNames = State(initialValue: initialNames)
    }

    public var body: some View {
        if speakerIndices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                if showsHeader {
                    Text("SPEAKERS")
                        .font(.harcCaption)
                        .foregroundStyle(Color.secondary)
                        .tracking(1.2)
                }
                ForEach(speakerIndices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                        row(for: index)
                        pendingSuggestionChip(for: index)
                        if let provider = suggestionsProvider {
                            suggestionChips(for: index, provider: provider)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: Binding(
                get: { addingPersonForIndex.map { IdxBox(value: $0) } },
                set: { addingPersonForIndex = $0?.value }
            )) { box in
                AddPersonNameSheet { name in
                    draftNames[box.value] = name
                    onCreatePerson(name, box.value)
                    addingPersonForIndex = nil
                } onCancel: {
                    addingPersonForIndex = nil
                }
            }
            .onChange(of: initialNames) { _, newNames in
                draftNames = newNames
            }
        }
    }

    private func row(for index: Int) -> some View {
        let currentLabel = draftNames[index] ?? "Speaker \(index + 1)"
        return HStack(spacing: HarcSpacing.md) {
            Text("Speaker \(index + 1)")
                .font(.harcBody)
                .foregroundStyle(Color.primary)
                .frame(minWidth: 78, idealWidth: 90, alignment: .leading)
            Menu {
                ForEach(allPeople) { p in
                    Button(p.displayName) {
                        draftNames[index] = p.displayName
                        onLinkPerson(p.id, index)
                    }
                }
                if !allPeople.isEmpty {
                    Divider()
                }
                Button("Add new person…") {
                    addingPersonForIndex = index
                }
                Divider()
                Button("Unassign") {
                    draftNames.removeValue(forKey: index)
                    onUnlinkPerson(index)
                }
            } label: {
                HStack {
                    Text(currentLabel)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.harcCaption)
                }
                .padding(.vertical, HarcSpacing.xs)
                .padding(.horizontal, HarcSpacing.sm)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pendingSuggestionChip(for index: Int) -> some View {
        if let suggestion = pendingSuggestions.first(where: { $0.speakerIndex == index }) {
            let personName = personNamesByID[suggestion.personID] ?? "someone"
            PendingSpeakerSuggestionRow(
                personName: personName,
                score: suggestion.score,
                onConfirm: { onConfirmSuggestion(suggestion) },
                onDismiss: { onDismissSuggestion(suggestion) }
            )
        }
    }

    @ViewBuilder
    private func suggestionChips(for index: Int, provider: SuggestionsProvider) -> some View {
        let raw = suggestions[index] ?? []
        let dismissed = dismissedSuggestionIDs[index] ?? []
        let visible = raw.filter { !dismissed.contains($0.id) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                ForEach(visible) { s in
                    SpeakerSuggestionChip(
                        suggestion: s,
                        onAccept: { acceptSuggestion(s, for: index) },
                        onDismiss: { dismissSuggestion(s, for: index) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Supporting types

private struct IdxBox: Identifiable {
    let value: Int
    var id: Int { value }
}

private struct PendingSpeakerSuggestionRow: View {
    let personName: String
    let score: Double
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            compactLayout
        }
        .padding(.horizontal, HarcSpacing.sm)
        .padding(.vertical, HarcSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.harc(.attention).opacity(0.12))
        )
    }

    private var horizontalLayout: some View {
        HStack(spacing: HarcSpacing.sm) {
            icon
            suggestionText
            Spacer(minLength: 8)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
                icon
                suggestionText
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: some View {
        Image(systemName: "questionmark.circle.fill")
            .foregroundStyle(Color.harc(.attention))
    }

    private var suggestionText: some View {
        Text("May be \(personName) · \(String(format: "%.2f", score))")
            .font(.harcCaption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: HarcSpacing.sm) {
            Button("Confirm", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }
}

private struct AddPersonNameSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.md) {
            Text("New person").font(.harcTitle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Add") { onSubmit(name.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(HarcSpacing.xl)
        .frame(width: 320)
    }
}
