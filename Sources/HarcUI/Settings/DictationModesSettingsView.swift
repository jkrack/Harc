import SwiftUI
import HarcModels

/// Settings → Dictation Modes section. Lists built-in + custom modes, with an
/// editor sheet for name/symbol/instruction/model, create/delete for custom
/// modes, and reset-to-default for built-ins.
public struct DictationModesSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var modeStore: DictationModeStore
    @EnvironmentObject private var models: ModelManagerStore

    @State private var editingMode: DictationMode?

    public init() {}

    public var body: some View {
        Section {
            Picker("Active mode", selection: activeModeBinding) {
                ForEach(modeStore.modes) { mode in
                    Label(mode.name, systemImage: mode.symbolName).tag(mode.id)
                }
            }
            .pickerStyle(.menu)

            ForEach(modeStore.modes) { mode in
                modeRow(mode)
            }

            Button {
                editingMode = DictationMode(
                    id: UUID().uuidString,
                    name: "New Mode",
                    symbolName: "sparkles",
                    postProcess: .llm,
                    instruction: "Output only the result, no preamble or explanation."
                )
            } label: {
                Label("Add Mode", systemImage: "plus")
            }
        } header: {
            Text("Dictation Modes")
        } footer: {
            Text("Modes reformat dictated text with the local model before inserting. If the model isn't available, the raw transcript is inserted instead.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .sheet(item: $editingMode) { mode in
            DictationModeEditor(
                mode: mode,
                isNew: !modeStore.modes.contains { $0.id == mode.id },
                onSave: { saved in
                    if modeStore.modes.contains(where: { $0.id == saved.id }) {
                        modeStore.update(saved)
                    } else {
                        modeStore.add(saved)
                    }
                    editingMode = nil
                },
                onCancel: { editingMode = nil }
            )
            .environmentObject(prefs)
            .environmentObject(models)
        }
    }

    private var activeModeBinding: Binding<String> {
        Binding(
            get: { modeStore.activeMode.id },
            set: { modeStore.setActiveMode(id: $0) }
        )
    }

    @ViewBuilder
    private func modeRow(_ mode: DictationMode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mode.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(mode.name)
            if mode.isBuiltIn {
                Text("Built-in")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mode.postProcess == .llm {
                Button("Edit") { editingMode = mode }
                    .buttonStyle(.borderless)
                if mode.isBuiltIn, mode != DictationMode.builtIn(id: mode.id) {
                    Button("Reset") { modeStore.resetBuiltIn(id: mode.id) }
                        .buttonStyle(.borderless)
                }
            }
            if !mode.isBuiltIn {
                Button(role: .destructive) {
                    modeStore.delete(id: mode.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Editor sheet

private struct DictationModeEditor: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var models: ModelManagerStore

    @State var mode: DictationMode
    let isNew: Bool
    let onSave: (DictationMode) -> Void
    let onCancel: () -> Void

    /// Sentinel for "follow the active summarizer" in the model picker.
    private static let followDefaultTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $mode.name)
                    TextField("SF Symbol", text: $mode.symbolName)
                    Toggle("Post-process with local model", isOn: postProcessBinding)
                } header: {
                    Text(isNew ? "New Mode" : "Edit Mode")
                }

                if mode.postProcess == .llm {
                    Section {
                        TextEditor(text: $mode.instruction)
                            .font(.body.monospaced())
                            .frame(minHeight: 110)
                    } header: {
                        Text("Instruction")
                    } footer: {
                        Text("Tell the model how to rewrite the dictated text. End with an explicit \"output only the result\" so it doesn't add commentary.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }

                    Section {
                        Picker("Model", selection: modelBinding) {
                            Text("Follow summarizer default").tag(Self.followDefaultTag)
                            ForEach(summarizers) { d in
                                Text(d.tierDisplayName)
                                    .tag(d.id)
                                    .disabled(!models.state(of: d.id).isInstalled)
                            }
                        }
                        .pickerStyle(.menu)
                    } footer: {
                        Text("Following the summarizer default shares the resident model — picking a different tier reloads multi-GB weights per switch.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }

                    Section {
                        Toggle("Include selected text", isOn: $mode.includeSelectedText)
                        Toggle("Include clipboard", isOn: $mode.includeClipboard)
                    } header: {
                        Text("Context")
                    } footer: {
                        Text("Captured when dictation starts and given to the model as reference material. Context is processed locally and never leaves this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") { onSave(mode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: mode.postProcess == .llm ? 480 : 240)
    }

    private var postProcessBinding: Binding<Bool> {
        Binding(
            get: { mode.postProcess == .llm },
            set: { mode.postProcess = $0 ? .llm : .none }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { mode.modelID ?? Self.followDefaultTag },
            set: { mode.modelID = $0 == Self.followDefaultTag ? nil : $0 }
        )
    }

    private var summarizers: [ModelDescriptor] {
        ModelCatalog.descriptors(for: .summarizer)
    }
}
