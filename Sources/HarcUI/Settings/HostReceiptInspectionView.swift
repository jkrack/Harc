import SwiftUI

/// Explicit local inspection of one canonical recording; no request runs on appear.
public struct HostReceiptInspectionView: View {
    @ObservedObject private var bridge: HarcAppBridge
    @State private var isExpanded: Bool

    public init(bridge: HarcAppBridge, initiallyExpanded: Bool = false) {
        self.bridge = bridge
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        DisclosureGroup("Inspect one recording (read-only)", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("Check one recording’s signed evidence without repairing it.")
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
                TextField("Canonical recording ID", text: $bridge.hostReceiptInspectionInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.harcMono)
                    .accessibilityIdentifier("harc.host.receipt-inspection.id")
                    .disabled(bridge.hostReceiptInspectionInProgress)
                Button("Inspect recording") {
                    Task { await bridge.requestHostReceiptInspection() }
                }
                .accessibilityIdentifier("harc.host.receipt-inspection.run")
                .disabled(bridge.hostReceiptInspectionInProgress
                    || bridge.hostReceiptRepairInProgress
                    || bridge.hostLibraryMigrationInProgress
                    || !bridge.hostRuntimeReady)
                if bridge.hostReceiptInspectionInProgress {
                    ProgressView("Inspecting one recording…")
                        .font(.harcLabel)
                }
                if let id = bridge.hostReceiptInspectedID {
                    Text("Recording: \(id.uuidString.lowercased())")
                        .font(.harcMono)
                        .textSelection(.enabled)
                }
                if let status = bridge.hostReceiptInspectionStatus {
                    Text(status)
                        .font(.harcLabel)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("harc.host.receipt-inspection.result")
                }
            }
            .padding(.vertical, HarcSpacing.sm)
        }
        .accessibilityIdentifier("harc.host.receipt-inspection")
    }
}
