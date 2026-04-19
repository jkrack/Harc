import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "mic") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "tray.full") }
            ProcessingSettingsView()
                .tabItem { Label("Processing", systemImage: "wand.and.rays") }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 560, minHeight: 440)
    }
}
