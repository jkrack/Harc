import SwiftUI

struct HarcMobileSyncDetailView<LocalRecordings: View>: View {
    @Environment(HarcMobileAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let presentation: HarcMobileSyncStatusPresentation
    let openHostSettings: () -> Void
    @ViewBuilder let localRecordings: () -> LocalRecordings

    var body: some View {
        List {
            Section("Recordings to Host") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title).font(.headline)
                    Text(presentation.detail).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(HarcMobileSyncAccessibilityID.transferStatus)
                LabeledContent("Pending recordings", value: "\(presentation.pendingCount)")
                    .accessibilityIdentifier(HarcMobileSyncAccessibilityID.pendingCount)
                if presentation.reason != .qualificationRequired,
                   let notice = presentation.qualificationNotice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                switch presentation.action {
                case .none:
                    EmptyView()
                case .hostSettings:
                    hostSettingsButton
                case .localRecordings:
                    localRecordingsLink
                case .retryTransfers:
                    Button("Retry transfers", systemImage: "arrow.clockwise") {
                        model.transferCoordinator?.retryPending()
                    }
                    .disabled(model.captureCoordinator?.isRecording ?? false)
                    .accessibilityIdentifier(HarcMobileSyncAccessibilityID.retryTransfers)
                }
            }
            Section("Host") {
                LabeledContent("Adopted Host", value: hostName ?? "No Host paired")
                    .accessibilityIdentifier(HarcMobileSyncAccessibilityID.host)
                Text(hostStatus.title)
                if let date = model.hostHealthCoordinator?.lastVerifiedAt {
                    LabeledContent("Last verified connection") {
                        Text(date, style: .relative)
                    }
                }
                if canCheckHost {
                    Button("Check Host connection", systemImage: "checkmark.shield") {
                        Task { await model.hostHealthCoordinator?.refresh() }
                    }
                    .disabled(model.hostHealthCoordinator?.isChecking ?? true)
                }
                hostSettingsButton
            }
            Section("Host Library") {
                if let library = model.libraryCoordinator {
                    let evidence = HarcMobileSyncLibraryEvidence(.init(library.state))
                    let status = HarcMobileCaptureStatusPresentation.library(
                        state: library.state,
                        recordingCount: library.recordings.count,
                        lastUpdatedAt: nil
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status.title).font(.headline)
                        Text(status.detail).foregroundStyle(.secondary)
                        if case .offline(let message) = library.state {
                            // The coordinator supplies fixed operation/status copy.
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(HarcMobileSyncAccessibilityID.library)
                    // Only a successful current refresh supplies this time.
                    // A Host probe or an old cache timestamp is not sync proof.
                    if let date = evidence.lastSuccessfulRefresh {
                        LabeledContent("Last successful Library refresh") {
                            Text(date, style: .relative)
                        }
                    } else {
                        Text("No successful Library refresh time is available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if evidence.action == .hostSettings {
                        hostSettingsButton
                    } else if evidence.action == .refresh, canCheckHost {
                        Button("Refresh Host Library", systemImage: "arrow.clockwise") {
                            library.refresh()
                        }
                        .disabled(library.isRefreshing)
                    }
                } else {
                    Text("Preparing Host Library status…")
                }
            } footer: {
                Text("Reading the Host Library is separate from sending new recordings. A verified Host connection does not mean recordings have synced.")
            }
            if presentation.action != .localRecordings {
                Section { localRecordingsLink }
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(HarcMobileSyncAccessibilityID.detail)
    }

    private var hostName: String? {
        model.hostHealthCoordinator?.hostDisplayName
            ?? model.pairingCoordinator?.pairedHostDisplayName
    }

    private var hostStatus: HarcMobileHostHealthStatus {
        model.hostHealthCoordinator?.status ?? .unpaired
    }

    private var canCheckHost: Bool {
        switch hostStatus {
        case .unpaired, .pairingRepairRequired: false
        case .checking, .connected, .unavailable: true
        }
    }

    private var hostSettingsButton: some View {
        Button("Open Host settings", systemImage: "macmini") {
            dismiss()
            openHostSettings()
        }
    }

    private var localRecordingsLink: some View {
        NavigationLink { localRecordings() } label: {
            Label("On This iPhone", systemImage: "iphone")
        }
        .accessibilityIdentifier(HarcMobileSyncAccessibilityID.localRecordings)
    }
}

extension HarcMobileSyncLibraryEvidence.State {
    init(_ state: HarcMobileLibraryCoordinator.State) {
        self = switch state {
        case .loadingCache: .preparing
        case .unpaired: .unpaired
        case .accessNotGranted: .accessNotGranted
        case .refreshing: .refreshing
        case .ready(let date): .ready(completedAt: date)
        case .offline: .offline
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

extension HarcMobileSyncStatusPresentation.Host {
    init(_ status: HarcMobileHostHealthStatus) {
        self = switch status {
        case .unpaired: .unpaired
        case .checking: .checking
        case .connected: .connected
        case .unavailable: .unavailable
        case .pairingRepairRequired: .repairRequired
        }
    }
}

extension HarcMobileSyncStatusPresentation.Transfer {
    init(_ state: HarcMobileTransferCoordinator.State) {
        self = switch state {
        case .idle: .idle
        case .encoding, .connecting, .uploading, .backgroundScheduled: .working
        case .waitingForPairing: .waitingForPairing
        case .codecQualificationRequired: .qualificationRequired
        case .retryNeeded: .retryNeeded
        case .securityBlocked: .securityBlocked
        case .uploaded: .receiptVerified
        }
    }
}
