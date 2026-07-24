import SwiftUI
import HarcCore

/// Everything that shapes what the transcript says. These knobs used to be
/// split across three non-adjacent places — chunk duration and voice-activity
/// detection under Recording, diarization and vocabulary under Processing —
/// so tuning transcript quality meant hunting through unrelated sections.
public struct TranscriptionSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var selection: Set<VocabularyEntry.ID> = []
    @State private var newFrom: String = ""
    @State private var newTo: String = ""

    public init() {}

    public var body: some View {
        Group {
            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
                    .tint(Color.accentColor)
                Toggle("Voice-activity detection", isOn: $prefs.vadEnabled)
                    .tint(Color.accentColor)
            } header: {
                Text("Speech")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speakers adds per-speaker segments to transcripts — worth keeping on for meetings, since it's what lets a downstream LLM tell participants apart.")
                    Text("Voice-activity detection skips silent regions before transcription. Faster and quieter on battery; disable if you suspect a word is being clipped.")
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            }

            Section {
                HStack {
                    Text("Chunk duration")
                    Spacer()
                    Text("\(Int(prefs.chunkDurationSeconds)) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $prefs.chunkDurationSeconds, in: 15...120, step: 15)
            } header: {
                Text("Background processing")
            } footer: {
                Text("How often the transcriber processes a slice while recording continues. Shorter slices finish sooner after you stop; longer slices give the model more context per pass.")
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
        .opacity(entry.enabled ? 1 : 0.55)
    }
}
