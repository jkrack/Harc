import SwiftUI
import HarcStore

public struct PersonDetailView: View {
    let personID: Int64
    let onSelectRecording: (Int64, Int) -> Void
    var onPersonDeleted: (() -> Void)?

    @StateObject private var viewModel: PersonDetailViewModel

    @State private var selectedSlots: Set<String> = []
    @State private var showingMergeSheet = false
    @State private var showingSplitSheet = false

    public init(
        personID: Int64,
        store: RecordingStore,
        onSelectRecording: @escaping (Int64, Int) -> Void,
        onPersonDeleted: (() -> Void)? = nil
    ) {
        self.personID = personID
        self.onSelectRecording = onSelectRecording
        self.onPersonDeleted = onPersonDeleted
        _viewModel = StateObject(wrappedValue: PersonDetailViewModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stats = viewModel.stats { statsLine(stats) }
                suggestionsSection
                utterancesSection
                voicePrintsSection
                thresholdSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: personID) {
            await viewModel.load(personID: personID)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PersonAvatar(displayName: viewModel.person?.displayName ?? "?", size: 44)
            Text(viewModel.person?.displayName ?? "Loading\u{2026}")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    @ViewBuilder
    private func statsLine(_ stats: PersonStats) -> some View {
        HStack(spacing: 8) {
            Text("\(stats.recordingCount) \(stats.recordingCount == 1 ? "recording" : "recordings")")
            Text("\u{00B7}").foregroundStyle(.secondary)
            Text(formatMs(stats.totalSpeakingMs)).foregroundStyle(.secondary)
            if let last = stats.lastSeen {
                Text("\u{00B7}").foregroundStyle(.secondary)
                Text("last seen \(last, style: .date)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        if !viewModel.pendingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Suggested matches (\(viewModel.pendingSuggestions.count))").font(.headline)
                    Spacer()
                    Button("Confirm all") {
                        Task { await viewModel.confirmAll() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ForEach(viewModel.pendingSuggestions) { s in
                    HStack(spacing: 8) {
                        Text("Recording #\(s.recordingID) Speaker \(s.speakerIndex + 1)")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", s.score))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Confirm") {
                            Task { await viewModel.confirm(s) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Skip") {
                            Task { await viewModel.dismiss(s) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }

    // MARK: - Utterances

    @ViewBuilder
    private var utterancesSection: some View {
        if !viewModel.utterances.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent utterances").font(.headline)
                ForEach(viewModel.utterances) { u in
                    Button {
                        onSelectRecording(u.recordingID, u.speakerIndex)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(u.recordingTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text("\u{00B7}").foregroundStyle(.secondary)
                                Text(formatTimestamp(u.startMs))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(u.snippet)
                                .font(.body)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        } else if viewModel.person != nil && viewModel.stats?.recordingCount == 0 {
            Text("No recordings yet. The next time this voice appears in a recording, link it from the Inspector to start building \(viewModel.person?.displayName ?? "this person")'s history.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Voice prints

    @ViewBuilder
    private var voicePrintsSection: some View {
        if !viewModel.embeddings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Voice prints (\(viewModel.embeddings.count))").font(.headline)
                    Spacer()
                    Button("Merge\u{2026}") { showingMergeSheet = true }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Split\u{2026}") { showingSplitSheet = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(selectedSlots.isEmpty)
                }
                ForEach(viewModel.embeddings, id: \.slotKey) { e in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selectedSlots.contains(e.slotKey) },
                            set: { isOn in
                                if isOn { selectedSlots.insert(e.slotKey) }
                                else { selectedSlots.remove(e.slotKey) }
                            }
                        ))
                        .labelsHidden()
                        Text("Recording #\(e.recordingID) Speaker \(e.speakerIndex + 1)")
                        Spacer()
                        Text("\(e.segmentCount) segs \u{00B7} \(e.totalMs / 1000)s \u{00B7} \(e.embedderKind ?? "\u{2014}")")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
            .sheet(isPresented: $showingMergeSheet) {
                MergePersonPicker(allPeople: viewModel.allPeopleForMerge) { targetID in
                    Task { await viewModel.merge(into: targetID) }
                    showingMergeSheet = false
                }
            }
            .sheet(isPresented: $showingSplitSheet) {
                SplitNameSheet { newName in
                    let slots = selectedSlots.compactMap { key -> (Int64, Int)? in
                        let parts = key.split(separator: "-")
                        guard parts.count == 2, let r = Int64(parts[0]), let s = Int(parts[1]) else { return nil }
                        return (r, s)
                    }
                    Task { await viewModel.split(slots: slots, newName: newName) }
                    selectedSlots.removeAll()
                    showingSplitSheet = false
                }
            }
        }
    }

    // MARK: - Threshold

    @ViewBuilder
    private var thresholdSection: some View {
        if let person = viewModel.person {
            VStack(alignment: .leading, spacing: 8) {
                Text("Match threshold").font(.headline)
                HStack {
                    Slider(value: Binding(
                        get: { person.matchThreshold ?? 0.65 },
                        set: { v in Task { await viewModel.updateThreshold(v) } }
                    ), in: 0.50...0.95)
                    Text(String(format: "%.2f", person.matchThreshold ?? 0.65))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 40)
                    if person.matchThreshold != nil {
                        Button("Reset") {
                            Task { await viewModel.updateThreshold(nil) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Text("Higher threshold = fewer false matches, more missed matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total / 60) % 60
        if h > 0 { return "\(h)h \(m)m total" }
        return "\(m)m total"
    }

    private func formatTimestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - SpeakerEmbeddingRow slot key

private extension RecordingStore.SpeakerEmbeddingRow {
    var slotKey: String { "\(recordingID)-\(speakerIndex)" }
}

// MARK: - MergePersonPicker

struct MergePersonPicker: View {
    let allPeople: [Person]
    let onSelect: (Int64) -> Void
    @State private var selected: Int64?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge into\u{2026}").font(.headline)
            if allPeople.isEmpty {
                Text("No other people exist yet.").foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selected) {
                    Text("Select\u{2026}").tag(Int64?.none)
                    ForEach(allPeople) { p in
                        Text(p.displayName).tag(Int64?.some(p.id))
                    }
                }
                .labelsHidden()
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Merge") {
                    if let id = selected { onSelect(id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - SplitNameSheet

struct SplitNameSheet: View {
    let onSubmit: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New person name").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Split") { onSubmit(name.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
