import AppKit
import SwiftUI

enum LocalStackHealthState: Equatable {
    case ready
    case warning
    case muted

    var iconName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .muted: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .muted: return .secondary
        }
    }
}

struct LocalStackHealthInput: Equatable {
    var destinationReady: Bool
    var destinationText: String
    var captureReady: Bool
    var captureText: String
    var sttReady: Bool
    var sttText: String
    var summarizerReady: Bool
    var summarizerText: String
    var embedderReady: Bool
    var embedderText: String
    var speakerIDReady: Bool
    var speakerIDText: String
    var notificationsReady: Bool
    var notificationsText: String
    var accessibilityReady: Bool
    var accessibilityText: String
}

struct LocalStackHealthItem: Identifiable, Equatable {
    enum ID: String {
        case destination
        case capture
        case stt
        case summarizer
        case embedder
        case speakerID
        case notifications
        case accessibility
    }

    var id: ID
    var title: String
    var detail: String
    var state: LocalStackHealthState
    var fixTitle: String?
}

enum LocalStackHealthModel {
    static func items(for input: LocalStackHealthInput) -> [LocalStackHealthItem] {
        [
            item(.destination, "Destination", input.destinationText, input.destinationReady, fixTitle: "Choose folder"),
            item(.capture, "Capture", input.captureText, input.captureReady, fixTitle: "Open permissions"),
            item(.stt, "STT", input.sttText, input.sttReady, fixTitle: "Check setup"),
            item(.summarizer, "Summaries", input.summarizerText, input.summarizerReady, mutedWhenUnavailable: true, fixTitle: "Install model"),
            item(.embedder, "Search", input.embedderText, input.embedderReady, mutedWhenUnavailable: true, fixTitle: "Install embedder"),
            item(.speakerID, "Speaker ID", input.speakerIDText, input.speakerIDReady, mutedWhenUnavailable: true, fixTitle: "Enable speaker ID"),
            item(.notifications, "Notifications", input.notificationsText, input.notificationsReady, mutedWhenUnavailable: true, fixTitle: "Open notifications"),
            item(.accessibility, "Paste", input.accessibilityText, input.accessibilityReady, mutedWhenUnavailable: true, fixTitle: "Open accessibility"),
        ]
    }

    private static func item(
        _ id: LocalStackHealthItem.ID,
        _ title: String,
        _ detail: String,
        _ ready: Bool,
        mutedWhenUnavailable: Bool = false,
        fixTitle: String
    ) -> LocalStackHealthItem {
        LocalStackHealthItem(
            id: id,
            title: title,
            detail: detail,
            state: ready ? .ready : (mutedWhenUnavailable ? .muted : .warning),
            fixTitle: ready ? nil : fixTitle
        )
    }
}

struct LocalStackHealthView: View {
    let items: [LocalStackHealthItem]
    var compact: Bool = false
    var onFix: (LocalStackHealthItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Local Stack", systemImage: "checklist.checked")
                    .font(compact ? .caption.weight(.semibold) : .headline)
                Spacer()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(summaryColor)
            }

            ForEach(visibleItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.state.iconName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.state.color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 1 : 2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if compact, let fixTitle = item.fixTitle {
                        Button(fixTitle) { onFix(item) }
                            .font(.caption)
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private var visibleItems: [LocalStackHealthItem] {
        compact ? items : items
    }

    private var summaryText: String {
        let warnings = items.filter { $0.state == .warning }.count
        if warnings > 0 { return "\(warnings) needs attention" }
        let muted = items.filter { $0.state == .muted }.count
        if muted > 0 { return "\(muted) optional off" }
        return "Ready"
    }

    private var summaryColor: Color {
        if items.contains(where: { $0.state == .warning }) { return .orange }
        if items.contains(where: { $0.state == .muted }) { return .secondary }
        return .green
    }
}
