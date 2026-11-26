import SwiftUI
import HarcStore

/// Read-only map, opened explicitly from Host Connections. It accepts an immutable
/// snapshot and has no Store, model, navigation or mutation capability.
struct ConfirmedProjectMapPanel: View {
    let snapshot: ConfirmedProjectMapSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcSpacing.lg) {
                Text("Accepted connections").font(.harcTitle).accessibilityAddTraits(.isHeader)
                Text("Snapshot of connections you accepted, not independently verified facts.")
                    .font(.harcCaption)
                VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                    Label("Selected recording", systemImage: "waveform").font(.harcLabel)
                    Text(verbatim: snapshot.recordingTitle).font(.harcBody)
                        .accessibilityIdentifier("projectMap.recordingTitle")
                }
                .padding(HarcSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: HarcSpacing.md).stroke(.secondary))
                if snapshot.connections.isEmpty {
                    Text("No accepted project connections in this snapshot. Possible connections may still exist.")
                        .font(.harcBody)
                }
                ForEach(snapshot.connections) { connection in
                    HStack(alignment: .top, spacing: HarcSpacing.md) {
                        Image(systemName: "arrow.turn.down.right").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                            Text(verbatim: connection.projectName).font(.harcLabel)
                            Text("Accepted association").font(.harcCaption)
                            Text(connection.evidenceIsCurrent
                                ? "Supporting source unchanged since review. This does not verify meaning."
                                : "Source or project changed since review. Your accepted connection is retained; its evidence needs review.")
                                .font(.harcCaption)
                            DisclosureGroup("Original supporting excerpt") {
                                Text("Partial historical context, not a current factual claim.").font(.harcCaption)
                                Text(verbatim: connection.originalQuote).font(.harcBody).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(HarcSpacing.lg)
                    .overlay(RoundedRectangle(cornerRadius: HarcSpacing.md).stroke(.secondary.opacity(0.35)))
                }
                if snapshot.hasMore {
                    Text("Showing the first \(snapshot.connections.count) accepted connections. More exist.")
                        .font(.harcCaption)
                }
            }
            .padding(HarcSpacing.xl)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 300)
    }
}

/// Lifecycle-aware explicit-selection presentation. Never leaves a prior map
/// behind on failure/loss. Release qualification is tracked separately.
struct SelectedConfirmedProjectMapPanel: View {
    @ObservedObject var controller: ConfirmedProjectMapController
    // Caller synchronously prepares a selection, passes its presentationID here,
    // then loads that same ticket in the presentation task. One token per view.
    let presentationID: UUID
    var body: some View {
        Group {
            if !controller.ownsPresentation(presentationID) {
                Text("This connection snapshot is no longer available. Select the recording again.")
            } else if controller.state == .ready, let snapshot = controller.snapshot {
                ConfirmedProjectMapPanel(snapshot: snapshot)
            } else if controller.state == .loading {
                ProgressView("Loading accepted connections")
            } else if controller.state == .invalidated {
                Text("Connections changed or are unavailable. Select the recording again to load a fresh snapshot.")
            } else {
                Text("Select a recording to view accepted project connections.")
            }
        }
        .onDisappear { controller.dismiss(presentationID: presentationID) }
    }
}
