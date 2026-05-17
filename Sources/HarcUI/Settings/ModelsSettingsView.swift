import SwiftUI
import HarcModels

/// Settings → Models tab. Lists the shipped models grouped by task, renders
/// install state per row, and lets the user pick the active summarizer.
///
/// Models are downloaded on demand — nothing is installed by default, and
/// features that need one prompt the user via `ModelRequirementView`.
public struct ModelsSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var models: ModelManagerStore

    @State private var ramGB: Int = Self.physicalRAMGB()
    @State private var pendingRemoveID: String?

    public init() {}

    public var body: some View {
        Group {
            Section {
                Text("Harc runs all AI work on your Mac. Download only the tiers you need.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } header: {
                Text("Models")
            }

            Section {
                ForEach(summarizers) { d in
                    ModelRow(descriptor: d, ramGB: ramGB,
                             onDownload: { download(d) },
                             onCancel:  { cancel(d) },
                             onRemove:  { pendingRemoveID = d.id })
                }
                activeSummarizerPicker
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summarization")
                    Text("Your Mac has \(ramGB) GB RAM")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                }
            } footer: {
                Text("Pick one tier. Higher tiers produce better summaries at higher RAM and time cost.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            if !embedders.isEmpty {
                Section {
                    ForEach(embedders) { d in
                        ModelRow(descriptor: d, ramGB: ramGB,
                                 onDownload: { download(d) },
                                 onCancel:  { cancel(d) },
                                 onRemove:  { pendingRemoveID = d.id })
                    }
                } header: {
                    Text("Semantic search")
                } footer: {
                    Text("Required to enable the Related tab in the library search.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .alert(
            "Remove this model?",
            isPresented: Binding(
                get: { pendingRemoveID != nil },
                set: { if !$0 { pendingRemoveID = nil } }
            ),
            presenting: pendingRemoveID
        ) { id in
            Button("Remove", role: .destructive) {
                Task {
                    // If removing the currently-active summarizer, roll the
                    // pref over to the highest installed tier (or the default)
                    // BEFORE the remove lands — otherwise the picker would
                    // briefly show its segment selected-but-disabled.
                    if prefs.activeSummarizerID == id {
                        let installed = Set(
                            ModelCatalog.descriptors(for: .summarizer)
                                .filter { models.state(of: $0.id).isInstalled }
                                .map(\.id)
                        )
                        prefs.activeSummarizerID = ModelCatalog.fallbackSummarizerID(
                            installed: installed,
                            excluding: id
                        )
                    }
                    await models.remove(id)
                    pendingRemoveID = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoveID = nil }
        } message: { id in
            if let d = ModelCatalog.descriptor(for: id) {
                Text("\(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file)) will be freed.")
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

    // MARK: - Active summarizer radio

    private var activeSummarizerPicker: some View {
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
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func download(_ d: ModelDescriptor) {
        Task {
            do {
                try await models.download(d.id)
            } catch {
                // State stream will also reflect failure; here we'd surface
                // a toast if we had one. For v1, the row's `.failed` state
                // renders the reason inline.
            }
        }
    }

    private func cancel(_ d: ModelDescriptor) {
        Task { await models.cancel(d.id) }
    }

    // MARK: - Data

    private var summarizers: [ModelDescriptor] {
        ModelCatalog.descriptors(for: .summarizer)
    }

    private var embedders: [ModelDescriptor] {
        ModelCatalog.downloadableDescriptors(for: .textEmbedder)
    }

    private static func physicalRAMGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return max(1, Int(bytes / (1024 * 1024 * 1024)))
    }
}

// MARK: - Row

private struct ModelRow: View {
    let descriptor: ModelDescriptor
    let ramGB: Int
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var models: ModelManagerStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(descriptor.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    statusChip
                }
                Text(descriptor.summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                if ramGB < descriptor.recommendedRAMGB {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Your Mac has \(ramGB) GB — \(descriptor.recommendedRAMGB) GB recommended.")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.yellow)
                }
                if case .failed(let reason) = state {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Color.red)
                }
                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 4)
    }

    private var state: ModelInstallState {
        models.state(of: descriptor.id)
    }

    @ViewBuilder
    private var statusChip: some View {
        if !descriptor.manifestVerified {
            chip("Manifest pending", color: Color.yellow)
        } else {
            switch state {
            case .installed:
                chip("Installed · \(sizeText)", color: Color.green)
            case .downloading:
                chip("Downloading · \(sizeText)", color: Color.accentColor)
            case .verifying:
                chip("Verifying", color: Color.accentColor)
            case .failed:
                chip("Failed", color: Color.red)
            case .absent:
                chip("Not installed · \(sizeText)", color: Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !descriptor.manifestVerified {
            Button("Download") { onDownload() }
                .controlSize(.small)
                .disabled(true)
                .help("Manifest hasn't been verified yet. Downloads are blocked until the manifest-refresh script runs.")
        } else {
            switch state {
            case .installed:
                Button("Remove", role: .destructive, action: onRemove)
                    .controlSize(.small)
            case .downloading, .verifying:
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            case .failed:
                Button("Retry", action: onDownload)
                    .controlSize(.small)
            case .absent:
                Button("Download") { onDownload() }
                    .controlSize(.small)
                    .disabled(ramGB < descriptor.minRAMGB)
            }
        }
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: descriptor.totalBytes, countStyle: .file)
    }

    private func chip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}
