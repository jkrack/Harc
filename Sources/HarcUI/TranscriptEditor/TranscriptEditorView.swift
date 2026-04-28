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
                .help("Save edits to disk")

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
                suggestionsProvider: nil
            )

            FileInspectorSection(recording: vm.recording)
        }
        .formStyle(.grouped)
        .background(.thinMaterial)
        .navigationTitle("Inspector")
    }

    // MARK: - Toolbar fields

    private var titleField: some View {
        TextField("Title", text: $titleDraft)
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
            EmptyTranscriptCard()
        } else if vm.editedText.isEmpty && vm.audioMissing {
            EmptyAudioOnlyCard()
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
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text("Timestamps approximate after edits.")
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
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { exportError = nil }
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

// MARK: - Empty states

private struct EmptyTranscriptCard: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                IdleWaveform()
                    .frame(width: 240, height: 56)
                    .opacity(0.6)
                Text("No transcript yet")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text("This recording is audio only. Transcribe on-device with parakeet-tdt-0.6b-v3 — typically a few seconds on Apple Silicon.")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct EmptyAudioOnlyCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "speaker.slash")
                .font(.system(size: 28))
                .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            Text("Audio file not found")
                .font(.headline)
                .foregroundStyle(Color.primary)
            Text("The original .wav for this recording is missing — playback is disabled. Editing still works if a transcript was previously saved.")
                .font(.body)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct IdleWaveform: View {
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<40, id: \.self) { i in
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(width: 2, height: barHeight(at: i, totalHeight: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func barHeight(at i: Int, totalHeight: CGFloat) -> CGFloat {
        let h = 8 + abs(sin(Double(i) * 0.5)) * Double(totalHeight - 8)
        return CGFloat(h)
    }
}
