import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarcStore
import HarcExport

public struct TranscriptEditorView: View {
    @ObservedObject var vm: TranscriptEditorViewModel
    @State private var titleDraft: String
    @FocusState private var titleFocused: Bool
    @State private var exportError: String?

    public init(vm: TranscriptEditorViewModel) {
        self.vm = vm
        self._titleDraft = State(initialValue: vm.recording.displayTitle)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            if let err = vm.saveError ?? exportError {
                errorBanner(err)
            }

            Divider().background(Color.harcBorderSubtle)

            body_
                .frame(maxHeight: .infinity)

            if vm.wordIndexStale {
                staleHintBanner
            }

            Divider().background(Color.harcBorderSubtle)

            TranscriptEditorTransportView(vm: vm)
        }
        .background(Color.harcSurface2)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleField
                metaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
    }

    private var titleField: some View {
        TextField("", text: $titleDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.harcInkPrimary)
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            .overlay(alignment: .bottom) {
                if titleFocused {
                    Rectangle()
                        .fill(Color.harcAccent)
                        .frame(height: 1)
                        .padding(.top, 24)
                }
            }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 5, height: 5)
            Text(stateLabel)
                .font(HarcDesign.Font.monoXs)
                .tracking(0.8)
                .foregroundStyle(Color.harcInkTertiary)
            metaSep
            Text(modelText)
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkTertiary)
            metaSep
            Text(durationText)
                .font(HarcDesign.Font.monoXs)
                .monospacedDigit()
                .foregroundStyle(Color.harcInkTertiary)
            metaSep
            Text(URL(fileURLWithPath: vm.recording.wavPath).lastPathComponent)
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var metaSep: some View {
        Text("·").foregroundStyle(Color.harcInkQuaternary).font(HarcDesign.Font.monoXs)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { copyPromptString() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                    Text("Copy for Prompt")
                        .font(HarcDesign.Font.meta)
                }
                .foregroundStyle(Color.harcAccent)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(vm.editedText.isEmpty)

            exportMenu

            saveButton
        }
        .padding(.top, 2)
    }

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
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
                Text("Export")
                    .font(HarcDesign.Font.meta)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.harcInkPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(Color.harcSurface3)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .stroke(Color.harcBorderStrong, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var saveButton: some View {
        Button { Task { await vm.save() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11, weight: .medium))
                Text("Save")
                    .font(HarcDesign.Font.meta.weight(.medium))
            }
            .foregroundStyle(vm.isDirty ? .white : Color.harcInkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(vm.isDirty ? Color.harcAccent : Color.harcSurface3)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .stroke(vm.isDirty ? Color.clear : Color.harcBorderStrong, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(!vm.isDirty)
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
                .foregroundStyle(Color.harcInkTertiary)
            Text("Timestamps approximate after edits.")
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcInkTertiary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(Color.harcSurface1)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.harcError)
            Text(message)
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcError)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { exportError = nil }
                .buttonStyle(.plain)
                .font(HarcDesign.Font.label)
                .foregroundStyle(Color.harcInkSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.harcError.opacity(0.08))
    }

    // MARK: - State derivations

    private var stateColor: Color {
        if vm.audioMissing { return Color.harcInkQuaternary }
        if vm.editedText.isEmpty { return Color.harcInkQuaternary }
        return HarcDesign.success
    }

    private var stateLabel: String {
        if vm.audioMissing { return "AUDIO MISSING" }
        if vm.editedText.isEmpty { return "AUDIO ONLY" }
        return "TRANSCRIBED"
    }

    private var modelText: String {
        // The model name isn't tracked per-recording yet; show the daemon default.
        "parakeet-tdt-0.6b-v3"
    }

    private var durationText: String {
        guard let end = vm.recording.endedAt else { return "—" }
        let total = Int(end.timeIntervalSince(vm.recording.startedAt))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    private func commitTitle() {
        titleFocused = false
        let cleaned = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await vm.renameTitle(cleaned.isEmpty ? nil : cleaned) }
    }

    private func copyPromptString() {
        let s = ExportService.promptString(for: vm.recording)
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
                try ExportService.write(recording: vm.recording, format: format, to: url)
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
                    .font(HarcDesign.Font.subtitle)
                    .foregroundStyle(Color.harcInkPrimary)
                Text("This recording is audio only. Transcribe on-device with parakeet-tdt-0.6b-v3 — typically a few seconds on Apple Silicon.")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
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
                .foregroundStyle(Color.harcInkQuaternary)
            Text("Audio file not found")
                .font(HarcDesign.Font.subtitle)
                .foregroundStyle(Color.harcInkPrimary)
            Text("The original .wav for this recording is missing — playback is disabled. Editing still works if a transcript was previously saved.")
                .font(HarcDesign.Font.body)
                .foregroundStyle(Color.harcInkSecondary)
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
                        .fill(Color.harcInkQuaternary)
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
