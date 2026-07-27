import SwiftUI
import HarcCore
import HarcStore

/// Everything that shapes what the transcript says. These knobs used to be
/// split across three non-adjacent places — chunk duration and voice-activity
/// detection under Recording, diarization and vocabulary under Processing —
/// so tuning transcript quality meant hunting through unrelated sections.
public struct TranscriptionSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var maintenance: LibraryMaintenanceStore
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
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
            }

            Section {
                HStack {
                    Text("Chunk duration")
                    Spacer()
                    Text("\(Int(prefs.chunkDurationSeconds)) s")
                        .font(.harcCaption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $prefs.chunkDurationSeconds, in: 15...120, step: 15)
            } header: {
                Text("Background processing")
            } footer: {
                Text("How often the transcriber processes a slice while recording continues. Shorter slices finish sooner after you stop; longer slices give the model more context per pass.")
                    .font(.harcLabel)
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
                                .font(.harcCaption)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    Text("Replace mis-heard words and acronyms in every new transcript — names, product terms, jargon.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                }
            } footer: {
                Text("Drag rows to reorder — rules apply top to bottom. Applies to new recordings only.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            }

            librarySection
        }
        .task { await maintenance.refreshBacklogs() }
    }

    /// Whole-library operations. Grouped here rather than under About because
    /// both are about transcript quality: one redoes transcripts with a better
    /// engine, the other makes existing ones findable.
    @ViewBuilder
    private var librarySection: some View {
        Section {
            Toggle("Blend meaning into search", isOn: $prefs.semanticSearchEnabled)
                .tint(Color.accentColor)

            LabeledContent {
                HStack(spacing: 8) {
                    Text(maintenance.indexBacklog == 0
                         ? "Up to date"
                         : "\(maintenance.indexBacklog) waiting")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                    Button("Build index") { maintenance.startIndexing() }
                        .disabled(maintenance.job.isRunning || maintenance.indexBacklog == 0)
                }
            } label: {
                Text("Search index")
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Text(maintenance.reprocessBacklog == 0
                         ? "All current"
                         : "\(maintenance.reprocessBacklog) older")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                    Button("Re-transcribe") { maintenance.startReprocess() }
                        .disabled(maintenance.job.isRunning || maintenance.reprocessBacklog == 0)
                }
            } label: {
                Text("Re-transcribe archive")
            }

            if maintenance.job.isRunning {
                maintenanceProgressRow
            } else if let outcome = maintenance.lastOutcome {
                Text(outcome)
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Your audio never left this Mac, so a better speech model can be applied to everything you have already recorded — not only to what you record next. Re-transcribing replaces transcript text and rebuilds that recording's search index.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private var maintenanceProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch maintenance.job {
            case .reprocessing(let progress):
                ProgressView(value: progress.fraction) {
                    Text(progress.currentTitle.map { "Re-transcribing \($0)" } ?? "Re-transcribing…")
                        .font(.harcCaption)
                }
                Text("\(progress.completed) of \(progress.total)"
                     + (progress.failed > 0 ? " · \(progress.failed) failed" : ""))
                    .font(.harcCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .indexing(let completed, let total):
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0) {
                    Text("Indexing transcripts…").font(.harcCaption)
                }
                Text("\(completed) of \(total)")
                    .font(.harcCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Stop") { maintenance.cancel() }
                    .font(.harcCaption)
            }
        }
    }

    @ViewBuilder
    private var vocabularyList: some View {
        if prefs.vocabulary.entries.isEmpty {
            Text("No vocabulary entries yet. Add one below.")
                .font(.harcLabel)
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
                .font(.harcBody)
                .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .foregroundStyle(Color.secondary)

            Text(entry.to)
                .font(.harcBody)
                .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                .strikethrough(!entry.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .opacity(entry.enabled ? 1 : 0.55)
    }
}
