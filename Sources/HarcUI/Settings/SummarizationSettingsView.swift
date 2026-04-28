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
        Group {
            Section {
                Text("Harc summarizes finished recordings locally using Gemma 4.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } header: {
                Text("Summarization")
            }

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
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)

                    if case .absent = models.state(of: prefs.activeSummarizerID) {
                        Text("The active summarizer is not installed. Auto-summarize and the Generate button will have no effect.")
                            .font(.subheadline)
                            .foregroundStyle(Color.yellow)
                    }
                }
            }

            Section {
                Toggle("Automatically summarize after recording", isOn: $prefs.autoSummarizeEnabled)
                Toggle("Also when on battery", isOn: $prefs.autoSummarizeOnBatteryEnabled)
                    .disabled(!prefs.autoSummarizeEnabled)
                    .padding(.leading, 16)
                Toggle("Include summary in exports and Copy for Prompt", isOn: $prefs.includeSummaryInPrompt)
            } header: {
                Text("Behavior")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemma 4 is multi-GB resident and uses power. The battery toggle is off by default.")
                    Text("When enabled, Markdown, DOCX, and prompt exports prepend Summary and Action Items above the transcript.")
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            }
        }
        .task {
            await models.bootstrap()
            ActiveSummarizerReconciler.reconcile(preferences: prefs, models: models)
        }
        .onChange(of: models.states) { _, _ in
            ActiveSummarizerReconciler.reconcile(preferences: prefs, models: models)
        }
        .onChange(of: prefs.activeSummarizerID) { _, _ in
            ActiveSummarizerReconciler.reconcile(preferences: prefs, models: models)
        }
    }

    private var activeTierPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active model")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Picker("", selection: $prefs.activeSummarizerID) {
                ForEach(summarizers) { d in
                    Text(d.tierDisplayName).tag(d.id)
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
}
