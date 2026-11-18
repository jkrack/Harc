import SwiftUI
import HarcStore
import HarcDomain

/// Resolves a session binding only from the current resident Host's store.
/// No phone or secondary-Mac writer path is introduced here.
struct HostProjectRefinementSheet: View {
    let store: RecordingStore
    @ObservedObject var bridge: HarcAppBridge
    let canWrite: @MainActor () -> Bool
    let source: Recording?
    let onOpenRecording: (CanonicalRecordingID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host: LibraryMetadata?
    @State private var failed = false
    @State private var reviewGeneration = UUID()
    @StateObject private var mapController: ConfirmedProjectMapController
    @State private var mapSelection: ConfirmedProjectMapController.PreparedSelection?

    init(store: RecordingStore, bridge: HarcAppBridge, canWrite: @escaping @MainActor () -> Bool,
         source: Recording?, onOpenRecording: @escaping (CanonicalRecordingID) -> Void) {
        self.store = store; self.bridge = bridge; self.canWrite = canWrite; self.source = source
        self.onOpenRecording = onOpenRecording
        _mapController = StateObject(wrappedValue: ConfirmedProjectMapController(store: store))
    }

    private var hostAvailable: Bool {
#if DEBUG
        if bridge.projectReviewFixtureReady { return canWrite() }
#endif
        return bridge.hostRuntimeReady && canWrite()
    }

    private func closeMap() {
        if let mapSelection { mapController.dismiss(presentationID: mapSelection.presentationID) }
        mapSelection = nil
    }

    private func openMap() {
        guard hostAvailable, let host, let source, let id = source.id,
              source.deletedAt == nil else { return }
        mapController.residentHostAvailabilityChanged(true)
        mapSelection = mapController.prepare(.init(recordingID: id,
            canonicalID: source.canonicalID, expectedHost: host))
    }

    var body: some View {
        VStack {
            HStack {
                Text("Connections").font(.harcTitle)
                Spacer()
                Button("Done") { closeMap(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(HarcSpacing.lg)
            if let host, hostAvailable {
                if let mapSelection {
                    HStack {
                        Button("Back to review") { closeMap() }
                            .accessibilityIdentifier("projectMap.back")
                        Spacer()
                        Button("Refresh selected recording") { openMap() }
                            .accessibilityIdentifier("projectMap.refresh")
                    }.padding(.horizontal, HarcSpacing.lg)
                    Text("If the Host changed, close and reopen Connections to use its current identity.")
                        .font(.harcCaption).padding(.horizontal, HarcSpacing.lg)
                    SelectedConfirmedProjectMapPanel(controller: mapController,
                        presentationID: mapSelection.presentationID)
                        .id(mapSelection.presentationID)
                        .task { await mapController.load(mapSelection) }
                } else {
                    Button("Accepted connections for selected recording", systemImage: "point.3.connected.trianglepath.dotted") {
                        openMap()
                    }
                    .disabled(source?.id == nil || source?.deletedAt != nil)
                    .accessibilityIdentifier("projectMap.open")
                    ProjectMentionConsentView(store: store, host: host, source: source, canWrite: canWrite) {
                        reviewGeneration = UUID()
                    }
                    ProjectRefinementPanel(store: store, expectedHost: host, canWrite: canWrite,
                                           onOpenRecording: onOpenRecording)
                        .id(reviewGeneration)
                }
            } else if failed || !hostAvailable {
                Text("Connections can only be reviewed on the active Mac Host.")
                    .font(.harcBody).padding(HarcSpacing.lg)
            } else {
                ProgressView("Opening Host connections…")
            }
        }
        .onDisappear { closeMap(); mapController.residentHostAvailabilityChanged(false) }
        .onChange(of: source?.id) { _, _ in closeMap(); mapController.selectionDidChange() }
        .onChange(of: source?.canonicalID) { _, _ in closeMap(); mapController.selectionDidChange() }
        .onChange(of: hostAvailable) { _, available in
            if !available { closeMap() }
            mapController.residentHostAvailabilityChanged(available)
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
