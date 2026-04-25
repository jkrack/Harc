import SwiftUI

public struct SettingsView: View {

    /// Identifies each tab so the "Open Models" link in
    /// `SummarizationSettingsView` can switch programmatically.
    public enum Tab: Hashable {
        case general, recording, library, processing, summarization, models
    }

    @State private var selectedTab: Tab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "mic") }
                .tag(Tab.recording)
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "tray.full") }
                .tag(Tab.library)
            ProcessingSettingsView()
                .tabItem { Label("Processing", systemImage: "wand.and.rays") }
                .tag(Tab.processing)
            SummarizationSettingsView(onOpenModels: { selectedTab = .models })
                .tabItem { Label("Summarization", systemImage: "sparkles") }
                .tag(Tab.summarization)
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "brain") }
                .tag(Tab.models)
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 560, minHeight: 440)
    }
}
