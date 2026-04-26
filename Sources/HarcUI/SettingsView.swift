import SwiftUI

public struct SettingsView: View {

    /// Identifies each tab so the "Open Models" link in
    /// `SummarizationSettingsView` can switch programmatically.
    enum Tab: Hashable {
        case recording, processing, summarization, models
    }

    @State private var selectedTab: Tab = .recording

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "mic") }
                .tag(Tab.recording)
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
