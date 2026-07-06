import SwiftUI

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Section {
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(HarcPreferences.Appearance.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("General")
        } footer: {
            Text("System follows your macOS appearance setting.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }
}
