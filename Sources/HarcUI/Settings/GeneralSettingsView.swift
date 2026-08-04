import SwiftUI
import ServiceManagement

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    /// Mirrors `SMAppService.mainApp.status` — refreshed on appear because the
    /// user can also change it in System Settings → Login Items.
    @State private var launchAtLogin = false
    @State private var proposedRole: HarcPreferences.RuntimeRole?

    public init() {}

    public var body: some View {
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
