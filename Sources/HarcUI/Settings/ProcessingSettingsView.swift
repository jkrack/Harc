import SwiftUI
import HarcCore

public struct ProcessingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var selection: Set<VocabularyEntry.ID> = []
    @State private var newFrom: String = ""
    @State private var newTo: String = ""

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
            } footer: {
                Text("When on, transcripts include per-speaker segments.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
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
                                .font(HarcDesign.Font.labelMd)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                    Text("Vocabulary")
                    Text("Replace mis-heard words and acronyms in every new transcript — names, product terms, jargon.")
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .textCase(nil)
                }
            } footer: {
                Text("Drag rows to reorder — rules apply top to bottom. Applies to new recordings only.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var vocabularyList: some View {
        if prefs.vocabulary.entries.isEmpty {
            Text("No vocabulary entries yet. Add one below.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcOnSurfaceVariant)
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
        HStack(spacing: HarcDesign.Space.xs) {
            TextField("Heard", text: $newFrom)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(Color.harcOnSurfaceVariant)
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
        HStack(spacing: HarcDesign.Space.xs) {
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
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(entry.enabled ? Color.harcOnSurface : Color.harcOnSurfaceVariant)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .foregroundStyle(Color.harcOnSurfaceVariant)

            Text(entry.to)
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(entry.enabled ? Color.harcOnSurface : Color.harcOnSurfaceVariant)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }
}
