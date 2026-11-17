import SwiftUI
import HarcStore
import HarcDomain

/// Resolves a session binding only from the current resident Host's store.
/// No phone or secondary-Mac writer path is introduced here.
struct HostProjectRefinementSheet: View {
    let store: RecordingStore
    let canWrite: @MainActor () -> Bool
    let source: Recording?
    let onOpenRecording: (CanonicalRecordingID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host: LibraryMetadata?
    @State private var failed = false
    @State private var reviewGeneration = UUID()

    var body: some View {
        VStack {
            HStack {
                Text("Connections").font(.harcTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(HarcSpacing.lg)
            if let host, canWrite() {
                ProjectMentionConsentView(store: store, host: host, source: source, canWrite: canWrite) {
                    reviewGeneration = UUID()
                }
                ProjectRefinementPanel(store: store, expectedHost: host, canWrite: canWrite,
                                       onOpenRecording: onOpenRecording)
                    .id(reviewGeneration)
            } else if failed || !canWrite() {
                Text("Connections can only be reviewed on the active Mac Host.")
                    .font(.harcBody).padding(HarcSpacing.lg)
            } else {
                ProgressView("Opening Host connections…")
            }
        }
        // token-exempt: sheet minimum usable window dimensions.
        .frame(minWidth: 560, minHeight: 420)
        .task {
            guard canWrite() else { failed = true; return }
            do {
                let metadata = try await store.libraryMetadata()
                guard !Task.isCancelled, canWrite(), metadata.writerMode == .host else {
                    failed = true; return
                }
                host = metadata
            } catch { failed = true }
        }
    }
}
