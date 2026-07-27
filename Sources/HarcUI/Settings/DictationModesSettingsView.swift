import SwiftUI
import HarcModels
import KeyboardShortcuts
import UniformTypeIdentifiers

/// Settings → Dictation Modes section. Lists built-in + custom modes, with an
/// editor sheet for name/symbol/instruction/model/shortcut, create/delete for
/// custom modes, reset-to-default for built-ins, and share via .harcmode files.
public struct DictationModesSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var modeStore: DictationModeStore
    @EnvironmentObject private var models: ModelManagerStore
    @EnvironmentObject private var bridge: HarcAppBridge

    @State private var editingMode: DictationMode?
    @State private var importError: String?

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

            HStack {
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
                Button {
                    runImportPanel()
                } label: {
                    Label("Import Mode…", systemImage: "square.and.arrow.down")
                }
            }
            if let importError {
                Text(importError)
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.failure))
            }
        } header: {
            Text("Dictation Modes")
        } footer: {
            Text("Modes reformat dictated text with the local model before inserting. If the model isn't available, the raw transcript is inserted instead.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
        .sheet(item: $editingMode) { mode in
            DictationModeEditor(
                mode: mode,
                isNew: !modeStore.modes.contains { $0.id == mode.id },
                testTransform: bridge.testDictationTransform,
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

    // MARK: - Share (.harcmode)

    private func runImportPanel() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.harcmodeType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let mode = try DictationModeIO.importMode(
                from: data,
                existingIDs: Set(modeStore.modes.map(\.id))
            )
            modeStore.add(mode)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func runExportPanel(for mode: DictationMode) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.harcmodeType]
        panel.nameFieldStringValue = "\(mode.name).\(DictationModeIO.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? DictationModeIO.exportData(mode) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `.harcmode` files are JSON with a distinct extension so they read as
    /// shareable mode files, not generic data.
    private static let harcmodeType =
        UTType(filenameExtension: DictationModeIO.fileExtension, conformingTo: .json) ?? .json

    private var activeModeBinding: Binding<String> {
        Binding(
            get: { modeStore.activeMode.id },
            set: { modeStore.setActiveMode(id: $0) }
        )
    }

    @ViewBuilder
    private func modeRow(_ mode: DictationMode) -> some View {
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: mode.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(mode.name)
            if mode.isBuiltIn {
                Text("Built-in")
                    .font(.harcCaption)
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
            Button {
                runExportPanel(for: mode)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Export mode as a .harcmode file")
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
    let testTransform: ((DictationMode, String) async throws -> String)?
    let onSave: (DictationMode) -> Void
    let onCancel: () -> Void

    @State private var testResult: String?
    @State private var testRunning = false
    @State private var manualBundleID = ""

    /// Sentinel for "follow the active summarizer" in the model picker.
    private static let followDefaultTag = ""
    private static let testSample =
        "um so basically we should uh probably move the sync to thursday morning"

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
                            .font(.harcBody.monospaced())
                            .frame(minHeight: 110)
                    } header: {
                        Text("Instruction")
                    } footer: {
                        Text("Tell the model how to rewrite the dictated text. End with an explicit \"output only the result\" so it doesn't add commentary.")
                            .font(.harcLabel)
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
                            .font(.harcLabel)
                            .foregroundStyle(Color.secondary)
                    }

                    Section {
                        Toggle("Include selected text", isOn: $mode.includeSelectedText)
                        Toggle("Include clipboard", isOn: $mode.includeClipboard)
                    } header: {
                        Text("Context")
                    } footer: {
                        Text("Captured when dictation starts and given to the model as reference material. Context is processed locally and never leaves this Mac.")
                            .font(.harcLabel)
                            .foregroundStyle(Color.secondary)
                    }

                    if testTransform != nil {
                        Section {
                            HStack {
                                Button("Test on a sample sentence") { runTest() }
                                    .disabled(testRunning)
                                if testRunning {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            if let testResult {
                                Text(testResult)
                                    .font(.harcBody)
                                    .textSelection(.enabled)
                            }
                        } footer: {
                            Text("Runs the instruction on: \u{201C}\(Self.testSample)\u{201D}")
                                .font(.harcLabel)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }

                Section {
                    KeyboardShortcuts.Recorder(
                        "Mode shortcut",
                        name: .dictationMode(mode.id)
                    )
                } footer: {
                    Text("Starts dictation straight into this mode, without changing the active mode.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    ForEach(mode.activationBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(Self.displayName(forBundleID: bundleID))
                            Text(bundleID)
                                .font(.harcCaption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                mode.activationBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        addRunningAppMenu
                        TextField("Or a bundle ID, e.g. com.apple.mail", text: $manualBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addManualBundleID() }
                        Button("Add") { addManualBundleID() }
                            .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Activate in these apps")
                } footer: {
                    Text("Dictating while one of these apps is frontmost uses this mode automatically. Mode shortcuts still win.")
                        .font(.harcLabel)
                        .foregroundStyle(Color.secondary)
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

    // MARK: - Activation rules

    /// Menu of currently running regular apps — the practical way to pick a
    /// target, since Settings itself is frontmost while this sheet is open.
    private var addRunningAppMenu: some View {
        Menu("Add App") {
            ForEach(Self.runningRegularApps(), id: \.bundleID) { app in
                Button(app.name) {
                    addBundleID(app.bundleID)
                }
            }
        }
        .fixedSize()
    }

    private func addManualBundleID() {
        addBundleID(manualBundleID)
        manualBundleID = ""
    }

    private func addBundleID(_ raw: String) {
        let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !mode.activationBundleIDs.contains(bundleID) else { return }
        mode.activationBundleIDs.append(bundleID)
    }

    private static func runningRegularApps() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func runTest() {
        guard let testTransform else { return }
        testRunning = true
        testResult = nil
        let candidate = mode
        Task { @MainActor in
            defer { testRunning = false }
            do {
                testResult = try await testTransform(candidate, Self.testSample)
            } catch {
                testResult = "Unavailable: \(error.localizedDescription)"
            }
        }
    }
}
