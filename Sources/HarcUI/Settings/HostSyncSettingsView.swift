import SwiftUI

/// Role, pairing, connectivity, recovery, and transport diagnostics live in
/// one place. General Settings should not require users to understand the
/// Host/Client architecture just to change appearance or launch behavior.
public struct HostSyncSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var bridge: HarcAppBridge
    @State private var proposedRole: HarcPreferences.RuntimeRole?

    public init() {}

    public var body: some View {
        Group {
            roleSection

            switch prefs.runtimeRole {
            case .standalone:
                standaloneSection
            case .client:
                clientConnectionSection
                clientRecoverySection
                clientPrivacySection
                clientDiagnosticsSection
                remoteSection
            case .host:
                hostSection
                remoteSection
            }
        }
        .confirmationDialog(
            "Change this Mac’s role?",
            isPresented: Binding(
                get: { proposedRole != nil },
                set: { if !$0 { proposedRole = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let role = proposedRole {
                Button("Use \(role.displayName) after restart") {
                    prefs.runtimeRole = role
                    proposedRole = nil
                }
            }
            Button("Cancel", role: .cancel) { proposedRole = nil }
        } message: {
            if proposedRole == .client {
                Text("Your current library remains local under On This Mac. Only recordings captured after Client mode starts enter the Host outbox.")
            } else {
                Text("Harc will preserve existing recordings and apply the new role on its next launch.")
            }
        }
    }

    private var roleSection: some View {
        Section {
            Picker(
                "This Mac",
                selection: Binding(
                    get: { prefs.runtimeRole },
                    set: { role in
                        guard role != prefs.runtimeRole else { return }
                        proposedRole = role
                    }
                )
            ) {
                ForEach(HarcPreferences.RuntimeRole.allCases) { role in
                    Text(role.displayName).tag(role)
                }
            }
        } header: {
            Text("Role")
        } footer: {
            Text("Role changes take effect after restarting Harc. Existing recordings remain in On This Mac and are never merged or uploaded implicitly.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var standaloneSection: some View {
        Section {
            Label("Everything stays on this Mac", systemImage: "checkmark.shield.fill")
                .foregroundStyle(Color.harc(.ready))
            Text("Choose Host to make this Mac the trusted library, or Client to send new captures to an adopted Host.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        } header: {
            Text("Standalone")
        }
    }

    private var clientConnectionSection: some View {
        Section {
            if !bridge.clientRuntimeReady {
                runtimeStartingOrFailed(role: "Client")
            } else {
                connectionStatusRow(bridge.clientHostConnectionState ?? .starting)
                Button(connectionActionTitle) {
                    bridge.onOpenHostPairing()
                }
            }
        } header: {
            Text("Host Connection")
        } footer: {
            Text("Paired means this Mac trusts a Host. Connected means Harc authenticated that Host during a live operation. The connection closes when work is finished.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func connectionStatusRow(_ state: ClientHostConnectionState) -> some View {
        HStack(alignment: .top, spacing: HarcSpacing.md) {
            Image(systemName: connectionSymbol(state))
                .foregroundStyle(connectionColor(state))
                .font(.harcBody)
                .frame(width: 20) // token-exempt: aligns status symbols in a fixed settings column.
            VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                Text(connectionTitle(state))
                    .font(.harcBody.weight(.semibold))
                Text(connectionDetail(state))
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastContact = state.lastContact {
                    HStack(spacing: HarcSpacing.xs) {
                        Text("Last authenticated")
                        Text(lastContact, style: .relative)
                    }
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .help(lastContact.formatted(date: .abbreviated, time: .standard))
                }
                Text(pendingText(state.pendingCount))
                    .font(.harcCaption)
                    .foregroundStyle(state.pendingCount == 0 ? .secondary : Color.harc(.attention))
            }
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private var clientRecoverySection: some View {
        Section {
            HStack(alignment: .top, spacing: HarcSpacing.md) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20) // token-exempt: aligns action symbols in a fixed settings column.
                VStack(alignment: .leading, spacing: HarcSpacing.xs) {
                    Text("Recover & Sync")
                        .font(.harcBody.weight(.semibold))
                    Text("Recover protected masters into this Mac's Library, transcribe them locally, then retry Host delivery.")
                        .font(.harcLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .completed(let report) = bridge.clientRecoverSyncState {
                        Text("Last result: \(report.headline)")
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                    } else if case .failed = bridge.clientRecoverSyncState {
                        Text("The last recovery needs attention. Open Activity for details.")
                            .font(.harcCaption)
                            .foregroundStyle(Color.harc(.attention))
                    }
                }
            }
            HStack(spacing: HarcSpacing.sm) {
                Button {
                    bridge.onRecoverAndSyncClient()
                } label: {
                    if bridge.clientRecoverSyncState?.isRunning == true {
                        HStack(spacing: HarcSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Recovering…")
                        }
                    } else {
                        Text("Recover & Sync")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !bridge.clientRuntimeReady
                        || bridge.clientRecoverSyncState?.isRunning == true
                )
                Button("Open Activity") { bridge.onOpenActivity() }
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Activity shows the full inventory report and every item that still needs attention.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var clientPrivacySection: some View {
        Section {
            Toggle("Allow Host audio downloads", isOn: $prefs.clientHostAudioDownloadEnabled)
                .disabled(prefs.clientHostAudioDownloadIsManaged)
            Toggle("Keep downloaded Host audio", isOn: $prefs.clientHostAudioRetentionEnabled)
                .disabled(
                    !prefs.clientHostAudioDownloadEnabled
                        || prefs.clientHostAudioRetentionIsManaged
                )
        } header: {
            Text("Client Privacy")
        } footer: {
            Text("Playback downloads verified audio only when allowed. Local capture and transcription remain available regardless of this setting.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var clientDiagnosticsSection: some View {
        Section {
            ClientDeveloperLogView(
                entries: bridge.clientDiagnosticLogEntries,
                onClear: bridge.onClearClientDiagnosticLog
            )
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Expand Developer Log to copy or save privacy-bounded connection and transfer events for troubleshooting.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var hostSection: some View {
        Section {
            if bridge.hostRuntimeReady {
                Label("Host is available to paired devices", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.harc(.ready))
                Button("Pair a Device…") { bridge.onOpenHostPairing() }
            } else {
                runtimeStartingOrFailed(role: "Host")
            }
        } header: {
            Text("Host")
        } footer: {
            Text("Pairing becomes available after Harc opens its local identity and network listeners.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var remoteSection: some View {
        Section {
            Toggle("Reach my Host from other networks", isOn: $prefs.remoteRelayEnabled)
                .disabled(!bridge.remoteRelayAvailable)
            LabeledContent("Status") {
                Text(bridge.remoteRelayStatusText)
                    .foregroundStyle(.secondary)
            }
            if let detail = bridge.remoteRelayStatusDetail {
                Label(detail, systemImage: "key.horizontal.fill")
                    .font(.harcLabel)
                    .foregroundStyle(Color.harc(.attention))
                    .textSelection(.enabled)
                if prefs.runtimeRole == .host,
                   bridge.remoteRelayStatusText == "Needs Keychain authorization" {
                    Button {
                        bridge.onAuthorizeRemoteRelay()
                    } label: {
                        if bridge.remoteRelayAuthorizationInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Authorize in Keychain…")
                        }
                    }
                    .disabled(bridge.remoteRelayAuthorizationInProgress)
                }
            }
        } header: {
            Text("Harc Remote")
        } footer: {
            Text(bridge.remoteRelayAvailable
                ? "Uses Cloudflare only as a blind byte relay. Harc’s pinned TLS remains inside the tunnel. Changes take effect after restarting Harc."
                : "Harc Remote is not configured in this build. Direct LAN pairing and queued transfer remain available.")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func runtimeStartingOrFailed(role: String) -> some View {
        if let error = bridge.runtimeStartupError {
            Label("\(role) could not start", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harc(.attention))
            Text(error)
                .font(.harcLabel)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            HStack(spacing: HarcSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Starting \(role)…")
            }
        }
    }

    private var connectionActionTitle: String {
        bridge.clientHostConnectionState?.isPaired == true
            ? "Manage Pairing…"
            : "Pair with Host…"
    }

    private func connectionTitle(_ state: ClientHostConnectionState) -> String {
        switch state {
        case .starting: "Checking Host connection…"
        case .notPaired: "Not paired with a Host"
        case .paired: "Paired — not currently connected"
        case .connecting: "Connecting securely to Host…"
        case .connected: "Connected securely to Host"
        case .needsAttention: "Host connection needs attention"
        case .securityBlocked: "Host connection blocked for security"
        }
    }

    private func connectionDetail(_ state: ClientHostConnectionState) -> String {
        switch state {
        case .starting:
            "Local Client storage is starting."
        case .notPaired:
            "Recordings stay protected on this Mac until you adopt a Host."
        case .paired(let lastContact, _):
            lastContact == nil
                ? "The Host is trusted, but Harc has not authenticated a live session yet."
                : "The Host is trusted. Harc reconnects automatically when work is waiting."
        case .connecting:
            "Harc is opening a pinned, authenticated Host session."
        case .connected:
            "A live authenticated Host operation is in progress."
        case .needsAttention(let message, _, _),
             .securityBlocked(let message, _, _):
            message
        }
    }

    private func connectionSymbol(_ state: ClientHostConnectionState) -> String {
        switch state {
        case .starting, .connecting: "arrow.triangle.2.circlepath"
        case .notPaired, .paired: "circle"
        case .connected: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .securityBlocked: "xmark.shield.fill"
        }
    }

    private func connectionColor(_ state: ClientHostConnectionState) -> Color {
        switch state {
        case .starting, .connecting: Color.harc(.working)
        case .notPaired, .paired: Color.secondary
        case .connected: Color.harc(.ready)
        case .needsAttention: Color.harc(.attention)
        case .securityBlocked: Color.harc(.failure)
        }
    }

    private func pendingText(_ count: Int) -> String {
        count == 0
            ? "No recordings waiting to sync"
            : "\(count) recording\(count == 1 ? "" : "s") waiting to sync"
    }
}
