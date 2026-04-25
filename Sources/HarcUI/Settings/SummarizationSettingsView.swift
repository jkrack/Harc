import SwiftUI
import HarcModels

/// Settings → Summarization tab. Auto-summarize + prompt-copy knobs, plus
/// a mirrored tier picker bound to the same `activeSummarizerID` key used
/// on the Models tab. `onOpenModels` is invoked by the "Open Models" link
/// so users install or remove tiers in the canonical place.
public struct SummarizationSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var models: ModelManagerStore

    public let onOpenModels: () -> Void

    public init(onOpenModels: @escaping () -> Void) {
        self.onOpenModels = onOpenModels
    }

    public var body: some View {
        Form {
            header

            Section {
                activeTierPicker
            } header: {
                Text("Model")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Install or remove tiers from the")
                        Button("Models tab") { onOpenModels() }
                            .buttonStyle(.link)
                    }
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)

                    if !models.state(of: prefs.activeSummarizerID).isInstalled {
                        Text("The active summarizer is not installed. Auto-summarize and the Generate button will have no effect.")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcWarning)
                    }
                }
            }

            Section {
                Toggle("Automatically summarize after recording", isOn: $prefs.autoSummarizeEnabled)
                Toggle("Also when on battery", isOn: $prefs.autoSummarizeOnBatteryEnabled)
                    .disabled(!prefs.autoSummarizeEnabled)
                    .padding(.leading, HarcDesign.Space.md)
                Toggle("Include summary in Copy for Prompt", isOn: $prefs.includeSummaryInPrompt)
            } header: {
                Text("Behavior")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 is multi-GB resident and uses power. The battery toggle is off by default.")
                    Text("\"Include summary in Copy for Prompt\" prepends ## Summary and ## Action Items above the transcript when copying.")
                }
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcInkSecondary)
            }
        }
        .formStyle(.grouped)
        .task { await models.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summarization")
                .font(HarcDesign.Font.title)
            Text("Harc summarizes finished recordings locally using Gemma 4.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private var activeTierPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active model")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcInkSecondary)
            Picker("", selection: $prefs.activeSummarizerID) {
                ForEach(summarizers) { d in
                    Text(tierName(d)).tag(d.id)
                        .disabled(!models.state(of: d.id).isInstalled)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var summarizers: [ModelDescriptor] {
        ModelCatalog.descriptors(for: .summarizer)
    }

    private func tierName(_ d: ModelDescriptor) -> String {
        switch d.tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .max:      return "Max"
        case .singleton: return d.displayName
        }
    }
}
