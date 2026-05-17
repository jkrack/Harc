import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarcStore
import HarcExport

public struct TranscriptEditorView: View {
    @ObservedObject var vm: TranscriptEditorViewModel
    let store: RecordingStore
    @State private var titleDraft: String
    @FocusState private var titleFocused: Bool
    @State private var exportError: String?
    @State private var inspectorOpen: Bool = false

    // People picker state for the inspector (Task 8.2)
    @State private var allPeople: [Person] = []
    @State private var allPeopleByID: [Int64: String] = [:]
    @State private var inspectorPendingSuggestions: [PendingSuggestion] = []

    public init(vm: TranscriptEditorViewModel, store: RecordingStore) {
        self.vm = vm
        self.store = store
        self._titleDraft = State(initialValue: vm.recording.displayTitle)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let err = vm.saveError ?? exportError {
                errorBanner(err)
            }

            body_
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if vm.wordIndexStale {
                staleHintBanner
            }

            Divider()

            TranscriptEditorTransportView(vm: vm)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                titleField
            }

            ToolbarItemGroup {
                Button { copyPromptString() } label: {
                    Label("Copy for Prompt", systemImage: "doc.on.clipboard")
                }
                .disabled(vm.editedText.isEmpty)
                .help("Copy transcript as LLM prompt")

                exportMenu

                Button { Task { await vm.save() } } label: {
                    Label("Save", systemImage: "arrow.down.doc")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!vm.isDirty)
                .help("Save (⌘S)")

                Button { inspectorOpen.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector")
            }
        }
        .inspector(isPresented: $inspectorOpen) {
            inspectorContent
        }
    }

    // MARK: - Inspector

    private var inspectorContent: some View {
        Form {
            SpeakerInspectorSection(
                speakerIndices: speakerIndices,
                initialNames: vm.recording.speakerNames,
                onCommit: { newNames in
                    guard let id = vm.recording.id else { return }
                    Task { try? await store.updateSpeakerNames(id: id, names: newNames) }
                },
                suggestionsProvider: nil,
                pendingSuggestions: inspectorPendingSuggestions,
                personNamesByID: allPeopleByID,
                onConfirmSuggestion: { s in
                    Task {
                        try? await store.confirmSuggestion(
                            personID: s.personID,
                            recordingID: s.recordingID,
                            speakerIndex: s.speakerIndex
                        )
                        if let id = vm.recording.id {
                            inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
                        }
                    }
                },
                onDismissSuggestion: { s in
                    Task {
                        try? await store.dismissSuggestion(
                            personID: s.personID,
                            recordingID: s.recordingID,
                            speakerIndex: s.speakerIndex
                        )
                        if let id = vm.recording.id {
                            inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
                        }
                    }
                },
                recordingID: vm.recording.id,
                allPeople: allPeople,
                onLinkPerson: { personID, speakerIndex in
                    guard let rid = vm.recording.id else { return }
                    Task { try? await store.linkSpeaker(personID: personID, recordingID: rid, speakerIndex: speakerIndex) }
                },
                onCreatePerson: { name, speakerIndex in
                    guard let rid = vm.recording.id else { return }
                    Task {
                        if let pid = try? await store.createPerson(displayName: name, matchThreshold: nil) {
                            try? await store.linkSpeaker(personID: pid, recordingID: rid, speakerIndex: speakerIndex)
                            let people = (try? await store.fetchPeople()) ?? []
                            allPeople = people
                            allPeopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
                        }
                    }
                },
                onUnlinkPerson: { speakerIndex in
                    guard let rid = vm.recording.id else { return }
                    Task { try? await store.unlinkSpeaker(recordingID: rid, speakerIndex: speakerIndex) }
                }
            )

            FileInspectorSection(recording: vm.recording)
        }
        .formStyle(.grouped)
        .background(.thinMaterial)
        .navigationTitle("Inspector")
        .task(id: vm.recording.id) {
            let people = (try? await store.fetchPeople()) ?? []
            allPeople = people
            allPeopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
            if let id = vm.recording.id {
                inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
            } else {
                inspectorPendingSuggestions = []
            }
        }
    }

    // MARK: - Toolbar fields

    private var titleField: some View {
        TextField("Recording title…", text: $titleDraft)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 200, maxWidth: 360)
            .focused($titleFocused)
            .onSubmit { commitTitle() }
    }

    // MARK: - Export menu

    private var exportMenu: some View {
        Menu {
            Section("Transcript") {
                Button("Markdown · .md") { runExport(.markdown) }
                Button("Plain Text · .txt") { runExport(.prompt) }
            }
            Section("Document") {
                Button("DOCX · .docx") { runExport(.docx) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: vm.recording.wavPath)]
                )
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export transcript")
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        if vm.editedText.isEmpty && vm.audioMissing == false {
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "No transcript yet",
                subtitle: "Transcribe this recording on-device to make it editable."
            )
        } else if vm.editedText.isEmpty && vm.audioMissing {
            EmptyStateView(
                icon: "speaker.slash",
                title: "Audio file not found",
                subtitle: "Playback is disabled because the original .wav is missing. Editing still works if a transcript was previously saved."
            )
        } else {
            TranscriptTextView(
                text: Binding(
                    get: { vm.editedText },
                    set: { vm.markEdited(newText: $0) }
                ),
                highlightRange: vm.currentHighlightRange,
                onCommandClick: { offset in vm.seekToWord(atCharOffset: offset) }
            )
            .background(Color.clear)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var staleHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text("Timestamps approximate after edits. Save to keep transcript text current; re-transcribe to rebuild word-level alignment.")
                .font(.caption)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Color.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") {
                exportError = nil
                vm.clearSaveError()
            }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    // MARK: - Helpers

    /// Distinct speaker indices derived from the document's parsed JSON segments.
    private var speakerIndices: [Int] {
        Array(Set(vm.document.speakers.map(\.speaker))).sorted()
    }

    private func commitTitle() {
        titleFocused = false
        let cleaned = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await vm.renameTitle(cleaned.isEmpty ? nil : cleaned) }
    }

    private func copyPromptString() {
        let s = ExportService.promptString(for: vm.recording, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func runExport(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService
            .defaultDestination(for: vm.recording, format: format)
            .lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: vm.recording.wavPath).deletingLastPathComponent()
        if let contentType = UTType(filenameExtension: format.filenameExtension) {
            panel.allowedContentTypes = [contentType]
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ExportService.write(recording: vm.recording, format: format, to: url, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
                exportError = nil
            } catch {
                exportError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
