import SwiftUI
import HarcStore

/// Read-only map, intentionally not installed in the app. It accepts an immutable
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
