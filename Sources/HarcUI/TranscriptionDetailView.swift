import SwiftUI
import AppKit
import HarcStore
import HarcExport
import HarcSummarize

public struct TranscriptionDetailView: View {
    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case transcript = "Transcript"
        case files = "Files"

        var id: String { rawValue }
    }

    let recording: Recording
    let store: RecordingStore?
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void
    let onEditTranscript: () -> Void
    let onSpeakerNamesChanged: ([Int: String]) -> Void
    let onClearSummary: (Int64) -> Void
    /// Provides speaker re-ID suggestions for a given speaker index.
    /// Optional — the editor renders chips when non-nil and the feature is
    /// enabled; when nil, the editor behaves exactly as pre-feature.
    let suggestionsProvider: SpeakerNameEditor.SuggestionsProvider?

    @EnvironmentObject private var prefs: HarcPreferences

    @State private var displayedRecording: Recording
    @State private var renameDraft: String
    @State private var isEditingTitle = false
    @State private var selectedTab: DetailTab = .overview
    @State private var transcript: String = ""
    @State private var transcriptDraft: String = ""
    @State private var isEditingTranscript = false
    @State private var isSavingTranscript = false
    @State private var loadError: String? = nil
    @State private var saveError: String? = nil
    @State private var deleteConfirm = false

    public init(
        recording: Recording,
        store: RecordingStore? = nil,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onEditTranscript: @escaping () -> Void = {},
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void,
        onClearSummary: @escaping (Int64) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        self.recording = recording
        self.store = store
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
        self.onEditTranscript = onEditTranscript
        self.onSpeakerNamesChanged = onSpeakerNamesChanged
        self.onClearSummary = onClearSummary
        self.suggestionsProvider = suggestionsProvider
        self._displayedRecording = State(initialValue: recording)
        self._renameDraft = State(initialValue: recording.title ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            header
            tabPicker
            Divider().overlay(Color.harcBorderSubtle)
            tabContent
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 760, minHeight: 560)
        .background(Color.harcSurface1)
        .onAppear(perform: load)
        .task { await observeRecording() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.md) {
            VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                if isEditingTitle {
                    TextField("Title", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(HarcDesign.Font.titleLg)
                        .onSubmit(commitTitleEdit)
                        .onExitCommand {
                            renameDraft = displayedRecording.title ?? ""
                            isEditingTitle = false
                        }
                } else {
                    Button {
                        isEditingTitle = true
                    } label: {
                        Text(displayedRecording.displayTitle)
                            .font(HarcDesign.Font.titleLg)
                            .foregroundStyle(Color.harcInkPrimary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: HarcDesign.Space.xs) {
                    Label(URL(fileURLWithPath: displayedRecording.wavPath).lastPathComponent, systemImage: "waveform")
                    Text("·")
                    Text(dateMeta)
                    if let duration = durationMeta {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(HarcDesign.Font.meta)
                .foregroundStyle(Color.harcInkSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: HarcDesign.Space.md)
            toolbar
        }
    }

    private var toolbar: some View {
        HStack(spacing: HarcDesign.Space.s3) {
            Menu {
                Button("Copy for Prompt")  { copyPromptString() }
                Button("Copy Plain Text")  { copyPlainText() }
            } label: {
                Label("Prompt", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(transcript.isEmpty)
            .help("Copy the prompt-formatted blob (default) or plain text")

            Button {
                let s = ExportService.promptString(for: displayedRecording, includeSummary: prefs.includeSummaryInPrompt)
                try? FrontmostAppPaster.copyAndPaste(s)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .controlSize(.regular)
            .disabled(transcript.isEmpty)
            .help("Copy the prompt blob to clipboard and paste into the frontmost app")

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
            .controlSize(.regular)

            Button(role: .destructive) {
                deleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.regular)
            .help("Delete recording")
            .alert("Delete recording?", isPresented: $deleteConfirm) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The recording's audio, transcript, and JSON files are moved to Trash and the entry is soft-deleted from the library.")
            }
        }
    }

    private var tabPicker: some View {
        Picker("Recording section", selection: $selectedTab) {
            ForEach(DetailTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 360)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewTab
        case .transcript:
            transcriptTab
        case .files:
            filesTab
        }
    }

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
                SummaryCardView(
                    recording: displayedRecording,
                    store: store,
                    activeSummarizerID: prefs.activeSummarizerID,
                    hasTranscript: hasTranscriptSource,
                    onClearSummary: onClearSummary
                )

                if !speakerIndices.isEmpty {
                    workspaceSection("Speakers") {
                        SpeakerNameEditor(
                            speakerIndices: speakerIndices,
                            initialNames: displayedRecording.speakerNames,
                            onCommit: onSpeakerNamesChanged,
                            suggestionsProvider: suggestionsProvider,
                            showsHeader: false
                        )
                    }
                }

                workspaceSection("Transcript Preview") {
                    transcriptPreview
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            HStack(spacing: HarcDesign.Space.xs) {
                Text("Transcript")
                    .font(HarcDesign.Font.subtitle)
                    .foregroundStyle(Color.harcInkPrimary)
                if let saveError {
                    Text(saveError)
                        .font(HarcDesign.Font.meta)
                        .foregroundStyle(Color.harcError)
                        .lineLimit(1)
                }
                Spacer()
                if isEditingTranscript {
                    Button("Cancel") {
                        transcriptDraft = transcript
                        isEditingTranscript = false
                        saveError = nil
                    }
                    .controlSize(.small)

                    Button {
                        Task { await saveTranscriptDraft() }
                    } label: {
                        Label(isSavingTranscript ? "Saving…" : "Save", systemImage: "arrow.down.doc")
                    }
                    .controlSize(.small)
                    .disabled(isSavingTranscript || transcriptDraft == transcript)
                } else {
                    Button {
                        transcriptDraft = transcript
                        isEditingTranscript = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .controlSize(.small)
                    .disabled(!hasTranscript)
                    .help("Edit this transcript in the recording workspace")
                }
            }

            transcriptBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
                workspaceSection("Recording Files") {
                    VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
                        fileRow("Audio", path: displayedRecording.wavPath)
                        if let txtPath = displayedRecording.txtPath {
                            fileRow("Transcript", path: txtPath)
                        }
                        if let jsonPath = displayedRecording.jsonPath {
                            fileRow("Sidecar", path: jsonPath)
                        }
                    }
                }

                workspaceSection("Summary Metadata") {
                    VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
                        metadataRow("Model", displayedRecording.summaryModelID ?? "No summary")
                        metadataRow("Generated", displayedRecording.summaryGeneratedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No summary")
                        metadataRow("Source words", displayedRecording.summarySourceWordCount.map(String.init) ?? "No summary")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let loadError {
            statusText(loadError, color: Color.harcError)
        } else if transcript.isEmpty {
            statusText("No transcript text is available.", color: Color.harcInkSecondary)
        } else if isEditingTranscript {
            TextEditor(text: $transcriptDraft)
                .font(HarcDesign.Font.body)
                .lineSpacing(4)
                .foregroundStyle(Color.harcInkPrimary)
                .scrollContentBackground(.hidden)
                .padding(HarcDesign.Space.sm)
                .background(
                    RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                        .fill(Color.harcSurface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                                .stroke(Color.harcAccent.opacity(0.45), lineWidth: 1)
                        )
                )
        } else {
            ScrollView {
                Text(transcript)
                    .font(HarcDesign.Font.body)
                    .lineSpacing(4)
                    .foregroundStyle(Color.harcInkPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HarcDesign.Space.md)
            }
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                    .fill(Color.harcSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                            .stroke(Color.harcBorderSubtle, lineWidth: 1)
                    )
            )
        }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            transcriptBody
                .frame(minHeight: 160, maxHeight: 240)
            Button {
                selectedTab = .transcript
            } label: {
                Label("View transcript", systemImage: "text.alignleft")
            }
            .buttonStyle(.plain)
            .font(HarcDesign.Font.body)
            .foregroundStyle(Color.harcAccent)
            .disabled(!hasTranscriptSource)
            .opacity(hasTranscriptSource ? 1 : 0.45)
        }
    }

    private func workspaceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.sm) {
            Text(title.uppercased())
                .font(HarcDesign.Font.label)
                .tracking(1.2)
                .foregroundStyle(Color.harcInkSecondary)
            content()
        }
    }

    private func fileRow(_ label: String, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcDesign.Space.sm) {
            Text(label)
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcInkSecondary)
                .frame(width: 88, alignment: .leading)
            Text(path)
                .font(HarcDesign.Font.mono)
                .foregroundStyle(Color.harcInkPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcDesign.Space.sm) {
            Text(label)
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcInkSecondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(HarcDesign.Font.body)
                .foregroundStyle(Color.harcInkPrimary)
            Spacer(minLength: 0)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(HarcDesign.Font.body)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(HarcDesign.Space.md)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                    .fill(Color.harcSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                            .stroke(Color.harcBorderSubtle, lineWidth: 1)
                    )
            )
    }

    private func commitTitleEdit() {
        let cleaned = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRename(cleaned.isEmpty ? nil : cleaned)
        isEditingTitle = false
    }

    private func copyPromptString() {
        let s = ExportService.promptString(for: displayedRecording, includeSummary: prefs.includeSummaryInPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private var dateMeta: String {
        displayedRecording.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var durationMeta: String? {
        guard let endedAt = displayedRecording.endedAt else { return nil }
        let seconds = max(0, Int(endedAt.timeIntervalSince(displayedRecording.startedAt).rounded()))
        let mins = seconds / 60
        let secs = seconds % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private func copyPlainText() {
        let input = ExportInputBuilder.build(from: displayedRecording)
        let text = input.segments.map { $0.text }.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private var hasTranscript: Bool {
        loadError == nil && !transcript.isEmpty
    }

    private var hasTranscriptSource: Bool {
        if let text = displayedRecording.transcriptText, !text.isEmpty { return true }
        guard let path = displayedRecording.txtPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func saveTranscriptDraft() async {
        guard let store else {
            saveError = "Cannot save transcript because the recording store is unavailable."
            return
        }
        isSavingTranscript = true
        defer { isSavingTranscript = false }
        do {
            let document = TranscriptDocument.load(recording: displayedRecording)
            _ = try document.save(editedText: transcriptDraft)
            if let id = displayedRecording.id {
                try await store.updateTranscriptText(id: id, text: transcriptDraft)
            }
            transcript = transcriptDraft
            saveError = nil
            isEditingTranscript = false
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Distinct speaker indices present in the recording, discovered by
    /// re-using `ExportInputBuilder.build` (which reads the sibling .json
    /// once). Empty array when the recording is un-diarized.
    private var speakerIndices: [Int] {
        let input = ExportInputBuilder.build(from: displayedRecording)
        var seen: Set<Int> = []
        for s in input.segments {
            if let id = s.speaker { seen.insert(id) }
        }
        return seen.sorted()
    }

    private func load() {
        loadError = nil
        if let cached = displayedRecording.transcriptText, !cached.isEmpty {
            transcript = cached
            transcriptDraft = cached
            return
        }
        guard let txtPath = displayedRecording.txtPath else {
            transcript = ""
            transcriptDraft = ""
            loadError = "No transcript file — recording likely had no transcription."
            return
        }
        do {
            transcript = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
            transcriptDraft = transcript
        } catch {
            loadError = "Failed to load transcript: \(error.localizedDescription)"
        }
    }

    private func observeRecording() async {
        guard let store, let id = recording.id else { return }
        for await latest in store.observe(id: id) {
            guard let latest else { continue }
            displayedRecording = latest
            if transcript.isEmpty {
                load()
            }
        }
    }
}
