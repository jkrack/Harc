import SwiftUI
import AppKit
import HarcStore

public struct TranscriptionDetailView: View {
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var transcript: String = ""
    @State private var loadError: String? = nil
    @State private var deleteConfirm = false

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(recording.displayTitle)
                        .font(HarcDesign.Font.titleLg)
                        .foregroundStyle(Color.harcOnSurface)
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
