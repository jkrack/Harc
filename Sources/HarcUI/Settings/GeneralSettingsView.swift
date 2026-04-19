import SwiftUI

public struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("General settings will appear here.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } footer: {
                Text("Future: launch at login, appearance, menu bar options.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
        }
        .formStyle(.grouped)
    }
}
