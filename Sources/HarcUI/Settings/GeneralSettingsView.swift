import SwiftUI
import ServiceManagement

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var bridge: HarcAppBridge
    /// Mirrors `SMAppService.mainApp.status` — refreshed on appear because the
    /// user can also change it in System Settings → Login Items.
    @State private var launchAtLogin = false
    @State private var proposedRole: HarcPreferences.RuntimeRole?

    public init() {}

    public var body: some View {
        Group {
            Section {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(HarcPreferences.Appearance.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
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
                Text("General")
            } footer: {
                Text(
                    "Role changes take effect after restarting Harc. Client keeps the existing local library as On This Mac and sends only new Client-mode captures to the paired Host. Nothing is merged or uploaded implicitly."
                )
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            }
            if prefs.runtimeRole == .client {
                Section {
                    if bridge.clientRuntimeReady {
                        Label("Client is ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Button("Pair with Host…") {
                            bridge.onOpenHostPairing()
                        }
                    } else if let error = bridge.runtimeStartupError {
                        Label(
                            "Client could not start",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(Color.orange)
                        Text(error)
                            .font(.harcLabel)
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                    } else {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting Client…")
                        }
                    }
                } header: {
                    Text("Client")
                } footer: {
                    Text(
                        "Pair this Mac by scanning a Host QR code. Its existing library remains separate under On This Mac."
                    )
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }
                Section {
                    Toggle(
                        "Allow Host audio downloads",
                        isOn: $prefs.clientHostAudioDownloadEnabled
                    )
                    .disabled(prefs.clientHostAudioDownloadIsManaged)
                    Toggle(
                        "Keep downloaded Host audio",
                        isOn: $prefs.clientHostAudioRetentionEnabled
                    )
                    .disabled(
                        !prefs.clientHostAudioDownloadEnabled
                            || prefs.clientHostAudioRetentionIsManaged
                    )
                } header: {
                    Text("Client Privacy")
                } footer: {
                    Text(
                        "Playback downloads verified audio only when allowed. By default, a work Mac removes that audio when playback ends. Managed preferences can lock either setting. Local capture and transcription remain available."
                    )
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }
            }
            if prefs.runtimeRole == .host {
                Section {
                    if bridge.hostRuntimeReady {
                        Label("Host is running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                        Button("Pair a Device…") {
                            bridge.onOpenHostPairing()
                        }
                    } else if let error = bridge.runtimeStartupError {
                        Label(
                            "Host could not start",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(Color.orange)
                        Text(error)
                            .font(.harcLabel)
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                    } else {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting Host…")
                        }
                    }
                } header: {
                    Text("Host")
                } footer: {
                    Text(
                        "Pairing is available after Harc opens its local identity and network listeners."
                    )
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }
            }
            if prefs.runtimeRole == .host || prefs.runtimeRole == .client {
                Section {
                    Toggle(
                        "Reach my Host from other networks",
                        isOn: $prefs.remoteRelayEnabled
                    )
                    .disabled(!bridge.remoteRelayAvailable)
                    LabeledContent("Status") {
                        Text(bridge.remoteRelayStatusText)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Harc Remote")
                } footer: {
                    Text(
                        bridge.remoteRelayAvailable
                            ? "Uses Cloudflare only as a blind byte relay. Harc’s pinned TLS remains inside the tunnel, so audio, transcripts, and library content stay encrypted. Changes take effect after restarting Harc."
                            : "Harc Remote is not configured in this build. Local capture, direct LAN pairing, and queued transfer remain available."
                    )
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }
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
                Text(
                    "Your current library remains local under On This Mac. Only recordings captured after Client mode starts enter the Host outbox."
                )
            } else {
                Text("Harc will preserve existing recordings and apply the new role on its next launch.")
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle if the system refused (e.g. managed Mac).
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
