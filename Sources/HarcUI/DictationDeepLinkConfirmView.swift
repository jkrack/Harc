import SwiftUI

/// Compact confirmation capsule for a `harc://dictate` link. Rendered in the
/// non-activating HUD panel, so clicking Start never steals focus from the
/// app the user intends to dictate into. The mic stays closed until Start.
struct DictationDeepLinkConfirmView: View {
    let request: DictationDeepLinkRequest
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.badge.plus")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Start", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect()
    }

    private var prompt: String {
        if let mode = request.mode {
            return "Start dictation in \(mode.name)?"
        }
        return "Start dictation?"
    }

    private var detail: String {
        "Requested by \(request.requesterName ?? "another app") via link"
    }
}
