import SwiftUI

public struct LibrarySettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text("Library settings will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } footer: {
                Text("Future: retention, search preferences, archive behavior.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
