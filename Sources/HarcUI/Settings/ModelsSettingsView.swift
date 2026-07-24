import SwiftUI
import HarcModels
import HarcSummarize

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
    /// Surfaced when `startDownload` throws before any state transition
    /// (low disk, another download running) — otherwise the click would
    /// visibly do nothing.
    @State private var downloadStartError: String?

    public init() {}

    public var body: some View {
        Group {
            Section {
                Text("Harc runs all AI work on your Mac. Download only the tiers you need.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                Picker("Performance", selection: $prefs.modelPerformanceMode) {
                    ForEach(HarcPreferences.ModelPerformanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(prefs.modelPerformanceMode.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } header: {
                Text("Models")
            }

            Section {
                if let downloadStartError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.yellow)
                        Text(downloadStartError)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        Button("Dismiss") { self.downloadStartError = nil }
                            .controlSize(.small)
                    }
                }
                ForEach(summarizers) { d in
                    ModelRow(descriptor: d, ramGB: ramGB,
                             onDownload: { download(d) },
                             onCancel:  { cancel(d) },
                             onRemove:  { pendingRemoveID = d.id })
                }
                activeSummarizerPicker
                if installedSummarizerCount >= 2, !extraInstalled.isEmpty {
                    reclaimSpaceCallout
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summarization")
                    Text("Your Mac has \(ramGB) GB RAM")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .textCase(nil)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick one tier. Higher tiers produce better summaries at higher RAM and time cost.")
                    Text("Models download over HTTPS from Hugging Face, pinned to an exact version and checksum-verified before install. Downloads are the only time Harc's AI touches the network — inference is fully on-device.")
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
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

    // MARK: - Reclaim space

    /// Shown when more than one summarizer is installed: each installed
    /// model except the active one, with a one-click (confirmed) Remove.
    /// Wording is careful not to call the extras unused — a dictation mode
    /// may pin a non-active model via its optional `modelID`.
    private var reclaimSpaceCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(Color.secondary)
                Text("You have \(installedSummarizerCount) models installed. Unless a dictation mode uses them, only the active one is needed.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            ForEach(extraInstalled) { d in
                HStack {
                    Text(d.tierDisplayName)
                        .font(.subheadline)
                    Spacer()
                    Button("Remove · \(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file))",
                           role: .destructive) {
                        pendingRemoveID = d.id
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private var installedSummarizerCount: Int {
        summarizers.filter { models.state(of: $0.id).isInstalled }.count
    }

    /// Installed summarizers other than the active one, largest first.
    private var extraInstalled: [ModelDescriptor] {
        summarizers
            .filter { models.state(of: $0.id).isInstalled && $0.id != prefs.activeSummarizerID }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - Actions

    private func download(_ d: ModelDescriptor) {
        downloadStartError = nil
        Task {
            do {
                try await models.download(d.id)
            } catch {
                // `startDownload` throws BEFORE any state transition (low
                // disk, another download running) — without this the click
                // does visibly nothing. Post-start failures render inline
                // via the row's `.failed` state.
                downloadStartError = error.localizedDescription
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
                // Provenance: link to the exact pinned revision so anyone can
                // inspect precisely what will be downloaded.
                Link(destination: descriptor.sourceURL) {
                    HStack(spacing: 3) {
                        Text(descriptor.repoID)
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                }
                .help("View this model at its pinned version on Hugging Face")
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
                chip("Installed · \(sizeText)\(measuredSpeedSuffix)", color: Color.green)
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

    /// " · ~27 tok/s on this Mac" once a summarization has measured this
    /// model here; empty until then (static row copy carries the estimate).
    private var measuredSpeedSuffix: String {
        guard let tps = MeasuredModelSpeed.tokensPerSecond(for: descriptor.id) else { return "" }
        return " · ~\(Int(tps.rounded())) tok/s"
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
