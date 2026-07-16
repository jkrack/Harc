import SwiftUI

/// One scrollable Form with grouped Sections — replaces the six-tab Settings TabView.
public struct HarcSettingsForm: View {
    public init() {}

    public var body: some View {
        Form {
            GeneralSettingsView()
            RecordingSettingsView()
            DictationModesSettingsView()
            ProcessingSettingsView()
            ModelsSettingsView()
            SummarizationSettingsView()
            AboutSettingsView()
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 480)
    }
}
