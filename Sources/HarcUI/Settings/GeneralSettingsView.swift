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

            Toggle("Markdown formatting ribbon", isOn: $prefs.markdownFormattingRibbonEnabled)
        } header: {
            Text("General")
        } footer: {
            Text("System follows your macOS appearance setting. The Markdown ribbon appears above note editors when enabled.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }
}
