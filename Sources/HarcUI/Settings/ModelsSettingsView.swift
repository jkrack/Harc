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
        Form {
            header

            Section {
                ForEach(summarizers) { d in
                    ModelRow(descriptor: d, ramGB: ramGB,
                             onDownload: { download(d) },
                             onCancel:  { cancel(d) },
                             onRemove:  { pendingRemoveID = d.id })
                }
                activeSummarizerPicker
            } header: {
                Text("Summarization")
            } footer: {
                Text("Pick one tier. Higher tiers produce better summaries at higher RAM and time cost. Your Mac has \(ramGB) GB.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)
            }

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
                Text("Required to enable the Related tab in the library search. 130 MB.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Remove this model?",
            isPresented: Binding(
                get: { pendingRemoveID != nil },
                set: { if !$0 { pendingRemoveID = nil } }
            ),
            presenting: pendingRemoveID
        ) { id in
            Button("Remove", role: .destructive) {
                Task { await models.remove(id); pendingRemoveID = nil }
            }
            Button("Cancel", role: .cancel) { pendingRemoveID = nil }
        } message: { id in
            if let d = ModelCatalog.descriptor(for: id) {
                Text("\(ByteCountFormatter.string(fromByteCount: d.totalBytes, countStyle: .file)) will be freed.")
            }
        }
        .task { await models.bootstrap() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models")
                .font(HarcDesign.Font.title)
            Text("Harc runs all AI work on your Mac. Download only the tiers you need.")
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    // MARK: - Active summarizer radio

    private var activeSummarizerPicker: some View {
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
        .padding(.top, 4)
    }

    private func tierName(_ d: ModelDescriptor) -> String {
        switch d.tier {
        case .standard: return "Standard"
        case .quality:  return "Quality"
        case .max:      return "Max"
        case .singleton: return d.displayName
        }
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
        ModelCatalog.descriptors(for: .textEmbedder)
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
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(descriptor.displayName)
                        .font(HarcDesign.Font.bodyMd)
                        .fontWeight(.medium)
                    statusChip
                }
                Text(descriptor.summary)
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcInkSecondary)
                if ramGB < descriptor.recommendedRAMGB {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Your Mac has \(ramGB) GB — \(descriptor.recommendedRAMGB) GB recommended.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.harcWarning)
                }
                if case .failed(let reason) = state {
                    Text(reason)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcError)
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
        switch state {
        case .installed:
            chip("Installed · \(sizeText)", color: HarcDesign.success)
        case .downloading:
            chip("Downloading · \(sizeText)", color: HarcDesign.accent)
        case .verifying:
            chip("Verifying", color: HarcDesign.accent)
        case .failed:
            chip("Failed", color: HarcDesign.danger)
        case .absent:
            chip("Not installed · \(sizeText)", color: HarcDesign.inkTertiary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
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

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: descriptor.totalBytes, countStyle: .file)
    }

    private func chip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(HarcDesign.Font.monoXs)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}
