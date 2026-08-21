import AppKit
import HarcCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared, privacy-bounded Client diagnostics renderer used by Settings and
/// Activity. Keeping one implementation prevents troubleshooting controls
/// from drifting between the two surfaces.
struct ClientDeveloperLogView: View {
    let entries: [HarcDiagnosticLogEntry]
    let onClear: () -> Void

    @State private var isExpanded: Bool
    @State private var exportError: String?

    init(
        entries: [HarcDiagnosticLogEntry],
        initiallyExpanded: Bool = false,
        onClear: @escaping () -> Void
    ) {
        self.entries = entries
        self.onClear = onClear
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                Text("Operational facts only — no audio, transcript text, credentials, pairing secrets, or full file paths are recorded.")
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: HarcSpacing.sm) {
                    Button("Copy Log") { copyLog() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(entries.isEmpty)
                    Button("Save…") { saveLog() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(entries.isEmpty)
                    Button("Clear") { onClear() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(entries.isEmpty)
                }

                if let exportError {
                    Text(exportError)
                        .font(.harcCaption)
                        .foregroundStyle(Color.harc(.failure))
                        .textSelection(.enabled)
                }

                if entries.isEmpty {
                    Text("No Client diagnostic events yet.")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries.suffix(60).reversed())) { entry in
                        row(entry)
                    }
                }
            }
            .padding(.top, HarcSpacing.sm)
        } label: {
            HStack(spacing: HarcSpacing.sm) {
                Label("Developer Log", systemImage: "terminal")
                    .font(.harcLabel.weight(.medium))
                Spacer()
                Text("\(entries.count) events")
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: HarcDiagnosticLogEntry) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
                Image(systemName: icon(entry.severity))
                    .foregroundStyle(color(entry.severity))
                Text("\(entry.area) · \(entry.stage)")
                    .font(.harcCaption.weight(.semibold))
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.harcCaption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.context.isEmpty {
                Text(entry.context.keys.sorted().map {
                    "\($0)=\(entry.context[$0] ?? "")"
                }.joined(separator: "  "))
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HarcSpacing.xs)
    }

    private func icon(_ severity: HarcDiagnosticSeverity) -> String {
        switch severity {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ severity: HarcDiagnosticSeverity) -> Color {
        switch severity {
        case .info: Color.harc(.working)
        case .success: Color.harc(.ready)
        case .warning: Color.harc(.attention)
        case .error: Color.harc(.failure)
        }
    }

    private var logText: String {
        HarcDiagnosticLogStore.formattedText(entries: entries)
    }

    private func copyLog() {
        exportError = nil
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(logText, forType: .string) else {
            exportError = "The diagnostic log could not be copied."
            return
        }
    }

    private func saveLog() {
        exportError = nil
        let panel = NSSavePanel()
        panel.title = "Save Client Diagnostic Log"
        panel.nameFieldStringValue = "Harc-Client-Diagnostic-Log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
