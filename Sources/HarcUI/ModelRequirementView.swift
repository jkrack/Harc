import SwiftUI
import HarcModels

/// Reusable card shown inline wherever a feature needs a model that isn't
/// installed yet. Typical use sites: summarization pane, semantic-search
/// "Related" tab. The card offers a one-click download; when the download
/// finishes, the feature auto-unlocks (the owning view observes the store).
public struct ModelRequirementView: View {
    public let descriptor: ModelDescriptor
    public let reason: String
    /// Optional callback when the user taps "Later" — owning feature may
    /// want to collapse the card to a one-liner link.
    public var onLater: (() -> Void)?

    @EnvironmentObject private var models: ModelManagerStore

    public init(
        descriptor: ModelDescriptor,
        reason: String,
        onLater: (() -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.reason = reason
        self.onLater = onLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            switch models.state(of: descriptor.id) {
            case .absent, .failed:
                actions
            case .downloading(let progress):
                progressRow(progress: progress)
            case .verifying:
                verifyingRow
            case .installed:
                // If the feature still shows us, the owning view hasn't refreshed —
                // render a short success note; it'll disappear next render.
                installedRow
            }

            if case .failed(let reason) = models.state(of: descriptor.id) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var title: String {
        "Needs \(descriptor.displayName)"
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: descriptor.totalBytes, countStyle: .file)
    }

    // MARK: - Sub-rows

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: download) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download \(sizeText)")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)

            if let onLater {
                Button("Later") { onLater() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
        }
    }

    private func progressRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack {
                Text(String(format: "%.0f %%", progress * 100))
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Spacer()
                Button("Cancel") {
                    Task { await models.cancel(descriptor.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.secondary)
            }
        }
    }

    private var verifyingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Verifying…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }

    private var installedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
            Text("Installed. Reopen to use.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Actions

    private func download() {
        Task { try? await models.download(descriptor.id) }
    }
}
