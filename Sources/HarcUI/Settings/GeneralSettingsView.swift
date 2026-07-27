import SwiftUI
import ServiceManagement

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    /// Mirrors `SMAppService.mainApp.status` — refreshed on appear because the
    /// user can also change it in System Settings → Login Items.
    @State private var launchAtLogin = false

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
        } header: {
            Text("General")
        } footer: {
            Text("System follows your macOS appearance setting.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
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
