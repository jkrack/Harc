import SwiftUI

/// Quick Capture (⌘⇧R) — the name-it-first start sheet. One keystroke from
/// any app, with the two decisions that actually matter — what's being
/// captured and whether to reach backwards — made before the meeting
/// starts instead of discovered in Settings afterwards. Naming up front is
/// what turns the library from timestamps into titles.
///
/// ⌃⌥R still starts instantly with a timestamp name; this sheet is the
/// deliberate path, not a gate.
public struct QuickCaptureView: View {
    @ObservedObject var prefs: HarcPreferences
    /// "5:00 banked" text when the retroactive ring is armed; nil hides the row.
    let bankedText: String?
    let onStart: (_ title: String, _ includePreRoll: Bool) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var includePreRoll = false
    @FocusState private var titleFocused: Bool

    public init(
        prefs: HarcPreferences,
        bankedText: String?,
        onStart: @escaping (_ title: String, _ includePreRoll: Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prefs = prefs
        self.bankedText = bankedText
        self.onStart = onStart
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            rows
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .onExitCommand { onCancel() }
        .onAppear { titleFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 20))
                .foregroundStyle(HarcBrand.live)
            TextField("Name this recording…", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium))
                .focused($titleFocused)
                .onSubmit { start() }
            if let shortcut = KeyboardShortcutsBadge.text(for: .quickCapture) {
                Text(shortcut)
                    .font(.harcMono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            row(
                symbol: "mic.fill",
                title: "Microphone",
                subtitle: nil
            ) {
                // The mic is the recording; a meeting capture without it is
                // nothing. Shown, not offered.
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(true)
            }
            row(
                symbol: "macwindow",
                title: "System audio — the other side of the call",
                subtitle: nil
            ) {
                Toggle("", isOn: $prefs.systemAudioEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let bankedText {
                row(
                    symbol: "clock",
                    title: "Include the last \(bankedText)",
                    subtitle: "Banked in memory · nothing written until you start"
                ) {
                    Toggle("", isOn: $includePreRoll)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func row(
        symbol: String,
        title: String,
        subtitle: String?,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.harcBody)
                if let subtitle {
                    Text(subtitle)
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Everything stays on this Mac")
                .font(.harcCaption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    Text("Start recording")
                        .font(.harcBody.weight(.semibold))
                    Text("↵")
                        .font(.harcMono)
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(HarcBrand.live, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("harc.quickCapture.start")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private func start() {
        onStart(title, includePreRoll)
    }
}

import KeyboardShortcuts

/// Render a KeyboardShortcuts binding as display text ("⌘⇧R"), or nil when
/// the user has removed the shortcut.
enum KeyboardShortcutsBadge {
    static func text(for name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:))
    }
}
