import SwiftUI
import HarcCore

public struct ProcessingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var selection: Set<VocabularyEntry.ID> = []
    @State private var newFrom: String = ""
    @State private var newTo: String = ""

    public init() {}

    public var body: some View {
        Group {
            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
            } header: {
                Text("Transcription")
            } footer: {
                Text("When on, transcripts include per-speaker segments.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            Section {
                vocabularyList
                addEntryRow
                if !selection.isEmpty {
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            prefs.deleteEntries(ids: selection)
                            selection = []
                        } label: {
                            Text("Delete \(selection.count) selected")
                                .font(.caption)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    Text("Replace mis-heard words and acronyms in every new transcript — names, product terms, jargon.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                }
            } footer: {
                Text("Drag rows to reorder — rules apply top to bottom. Applies to new recordings only.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var vocabularyList: some View {
        if prefs.vocabulary.entries.isEmpty {
            Text("No vocabulary entries yet. Add one below.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(selection: $selection) {
                ForEach(prefs.vocabulary.entries) { entry in
                    VocabularyRow(entry: entry, prefs: prefs)
                        .tag(entry.id)
                }
                .onMove { source, destination in
                    prefs.moveEntries(fromOffsets: source, toOffset: destination)
                }
                .onDelete { indices in
                    let ids = indices.map { prefs.vocabulary.entries[$0].id }
                    prefs.deleteEntries(ids: Set(ids))
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
    }

    private var addEntryRow: some View {
        HStack(spacing: 8) {
            TextField("Heard", text: $newFrom)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(Color.secondary)
            TextField("Replace with", text: $newTo)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let from = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
                let to = newTo.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !from.isEmpty, !to.isEmpty else { return }
                prefs.addEntry(from: from, to: to)
                newFrom = ""
                newTo = ""
            }
            .disabled(
                newFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    @ObservedObject var prefs: HarcPreferences

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { entry.enabled },
                    set: { _ in prefs.toggleEntry(id: entry.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(entry.from)
                .font(.body)
                .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .foregroundStyle(Color.secondary)

            Text(entry.to)
                .font(.body)
                .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
