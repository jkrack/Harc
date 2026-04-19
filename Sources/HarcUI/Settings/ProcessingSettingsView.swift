import SwiftUI

public struct ProcessingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Transcribe speakers (diarization)", isOn: $prefs.diarize)
            } footer: {
                Text("When on, transcripts include per-speaker segments.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }

            Section {
                Text("Vocabulary editor coming next.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("User-defined word replacements applied to new recordings.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
        }
        .formStyle(.grouped)
    }
}
