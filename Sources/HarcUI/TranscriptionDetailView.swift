import SwiftUI
import AppKit
import HarcStore
import HarcExport
import HarcSummarize

public struct TranscriptionDetailView: View {
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void
    let onSpeakerNamesChanged: ([Int: String]) -> Void
    let onClearSummary: (Int64) -> Void
    /// Provides speaker re-ID suggestions for a given speaker index.
    /// Optional — the editor renders chips when non-nil and the feature is
    /// enabled; when nil, the editor behaves exactly as pre-feature.
    let suggestionsProvider: SpeakerNameEditor.SuggestionsProvider?

    @EnvironmentObject private var prefs: HarcPreferences

    @State private var renameDraft: String
    @State private var isEditingTitle = false
    @State private var transcript: String = ""
    @State private var loadError: String? = nil
    @State private var deleteConfirm = false

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void,
        onClearSummary: @escaping (Int64) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
        self.onSpeakerNamesChanged = onSpeakerNamesChanged
        self.onClearSummary = onClearSummary
        self.suggestionsProvider = suggestionsProvider
        self._renameDraft = State(initialValue: recording.title ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    if isEditingTitle {
                        TextField("Title", text: $renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(HarcDesign.Font.titleLg)
                            .onSubmit {
                                let cleaned = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                onRename(cleaned.isEmpty ? nil : cleaned)
                                isEditingTitle = false
                            }
                    } else {
                        Button {
                            isEditingTitle = true
                        } label: {
                            Text(recording.displayTitle)
                                .font(HarcDesign.Font.titleLg)
                                .foregroundStyle(Color.harcOnSurface)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(URL(fileURLWithPath: recording.wavPath).lastPathComponent)
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Spacer()
                toolbar
            }

            SummaryCardView(
                recording: recording,
                activeSummarizerID: prefs.activeSummarizerID,
                onClearSummary: onClearSummary
            )

            SpeakerNameEditor(
                speakerIndices: speakerIndices,
                initialNames: recording.speakerNames,
                onCommit: onSpeakerNamesChanged,
                suggestionsProvider: suggestionsProvider
            )

            if let loadError {
                Text(loadError)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcError)
            } else if transcript.isEmpty {
                Text("(no transcript)")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } else {
                ScrollView {
                    Text(transcript)
                        .font(HarcDesign.Font.bodyMd)
                        .foregroundStyle(Color.harcOnSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HarcDesign.Space.md)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
            }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: load)
    }

    private var toolbar: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Menu {
                Button("Copy for Prompt")  { copyPromptString() }
                Button("Copy Plain Text")  { copyPlainText() }
            } label: {
                Label("Copy for Prompt", systemImage: "doc.on.clipboard")
            }
            .menuStyle(.borderlessButton)
            .disabled(transcript.isEmpty)
            .help("Copy the prompt-formatted blob (default) or plain text")

            Button {
                let s = ExportService.promptString(for: recording, includeSummary: prefs.includeSummaryInPrompt)
                try? FrontmostAppPaster.copyAndPaste(s)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("Copy the prompt blob to clipboard and paste into the frontmost app")

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }

            Button(role: .destructive) {
                deleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .alert("Delete recording?", isPresented: $deleteConfirm) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The recording's audio, transcript, and JSON files are moved to Trash and the entry is soft-deleted from the library.")
            }
        }
    }

    private func copyPromptString() {
        let s = ExportService.promptString(for: recording, includeSummary: prefs.includeSummaryInPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func copyPlainText() {
        let input = ExportInputBuilder.build(from: recording)
        let text = input.segments.map { $0.text }.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Distinct speaker indices present in the recording, discovered by
    /// re-using `ExportInputBuilder.build` (which reads the sibling .json
    /// once). Empty array when the recording is un-diarized.
    private var speakerIndices: [Int] {
        let input = ExportInputBuilder.build(from: recording)
        var seen: Set<Int> = []
        for s in input.segments {
            if let id = s.speaker { seen.insert(id) }
        }
        return seen.sorted()
    }

    private func load() {
        if let cached = recording.transcriptText, !cached.isEmpty {
            transcript = cached
            return
        }
        guard let txtPath = recording.txtPath else {
            loadError = "No transcript file — recording likely had no transcription."
            return
        }
        do {
            transcript = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
        } catch {
            loadError = "Failed to load transcript: \(error.localizedDescription)"
        }
    }
}
