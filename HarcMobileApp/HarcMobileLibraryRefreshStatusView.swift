import SwiftUI

/// Reading status never owns or cancels the refresh. Back and Done remain usable,
/// and returning to either surface shows the coordinator's retained outcome.
struct HarcMobileLibraryRefreshStatusView: View {
    let state: HarcMobileLibraryCoordinator.State
    let hasRows: Bool
    let refreshIsActive: Bool
    let refresh: () -> Void
    let setup: () -> Void

    var body: some View {
        let status = HarcMobileLibraryRefreshPresentation.status(state, hasRows: hasRows)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if status.isLoading {
                    ProgressView(status.title)
                } else {
                    Label(status.title, systemImage: status.symbol)
                        .font(.headline)
                }
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("harc.mobile.library.refresh-status")

            if let action = status.action {
                Button {
                    if action == .setup { setup() } else { refresh() }
                } label: {
                    Text(action == .setup ? "Setup & Sync" : "Refresh Library")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(action == .refresh && refreshIsActive)
                .accessibilityIdentifier("harc.mobile.library.refresh-action")
                if action == .refresh, case .failed = state {
                    setupButton
                } else if action == .refresh, case .offline = state {
                    setupButton
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
    }

    private var setupButton: some View {
        Button(action: setup) {
            Text("Setup & Sync")
                .frame(minHeight: 44, alignment: .leading)
        }
            .accessibilityIdentifier("harc.mobile.library.refresh-setup")
    }
}
