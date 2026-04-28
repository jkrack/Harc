import SwiftUI

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Section {
            Text("General settings will appear here.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        } header: {
            Text("General")
        } footer: {
            Text("Future: launch at login, appearance, menu bar options.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }
}
