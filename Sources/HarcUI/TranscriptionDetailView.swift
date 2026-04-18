import SwiftUI
import AppKit
import HarcStore

public struct TranscriptionDetailView: View {
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void

    @State private var renameDraft: String
    @State private var isEditingTitle = false
    @State private var transcript: String = ""
    @State private var loadError: String? = nil
    @State private var deleteConfirm = false

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
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
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
            }
            .disabled(transcript.isEmpty)

            Button {
                try? FrontmostAppPaster.copyAndPaste(transcript)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("Copy to clipboard and paste into the frontmost app")

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
