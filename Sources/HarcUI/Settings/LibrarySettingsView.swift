import SwiftUI

public struct LibrarySettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("Library settings will appear here.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } footer: {
                Text("Future: retention, search preferences, archive behavior.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
        }
        .formStyle(.grouped)
    }
}
