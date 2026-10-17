import SwiftUI
import HarcAudio

/// Shared microphone selector for Quick Capture, the Library record card, and
/// Recording settings. It deliberately includes an unavailable persisted route
/// so a dock disconnect never looks like Harc forgot the user's choice.
public struct MicrophonePickerControl: View {
    @ObservedObject private var bridge: HarcAppBridge
    @ObservedObject private var recordingState: RecordingState
    private let showsLabel: Bool
    @State private var isPresented = false
    @State private var hoveredMicrophone: String?

    public init(bridge: HarcAppBridge, showsLabel: Bool = false) {
        self.bridge = bridge
        self.recordingState = bridge.recordingState
        self.showsLabel = showsLabel
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: HarcSpacing.xs) {
                if showsLabel {
                    Label("Microphone", systemImage: "mic")
                }
                Image(systemName: "chevron.down")
                    .font(.harcCaption.weight(.semibold))
            }
            // token-exempt: fixed compact hit target keeps the anchor stable when opened.
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: HarcSpacing.sm))
            .background(
                Color.primary.opacity(isPresented ? 0.12 : 0.05),
                in: RoundedRectangle(cornerRadius: HarcSpacing.sm)
            )
        }
        .buttonStyle(.plain)
        .disabled(recordingState.isActiveOrPreparing)
        .help("Choose microphone — \(bridge.selectedMicrophoneName)")
        .accessibilityLabel("Choose microphone")
        .accessibilityValue("\(bridge.selectedMicrophoneName), \(isPresented ? "expanded" : "collapsed")")
        .accessibilityIdentifier("harc.microphonePicker")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            microphonePopover
        }
        .onChange(of: recordingState.isActiveOrPreparing) { _, active in
            if active { isPresented = false }
        }
    }

    private var microphonePopover: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            Label("Microphone", systemImage: "mic")
                .font(.harcLabel)
                .foregroundStyle(.secondary)
                .padding(.horizontal, HarcSpacing.sm)
            Divider()
            ScrollView {
                VStack(spacing: HarcSpacing.xs) {
                    microphoneRow(systemDefaultLabel, uid: nil)
                    ForEach(bridge.availableMicrophones) { device in
                        microphoneRow(device.name, uid: device.uid)
                    }
                    if let uid = unavailableSelectedUID {
                        microphoneRow("\(bridge.selectedMicrophoneName) — disconnected", uid: uid)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // token-exempt: bound the separate device popover on small screens.
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HarcSpacing.md)
        // token-exempt: device names need a wider surface than the collapsed control.
        .frame(width: 340)
        .onExitCommand { isPresented = false }
        .accessibilityIdentifier("harc.microphonePicker.popover")
    }

    private func microphoneRow(_ name: String, uid: String?) -> some View {
        let selected = bridge.microphoneSelection.deviceUID == uid
        return Button {
            guard !recordingState.isActiveOrPreparing else { return }
            bridge.onSelectMicrophone(uid)
            isPresented = false
        } label: {
            HStack(spacing: HarcSpacing.sm) {
                Text(name)
                    .font(.harcBody)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: HarcSpacing.sm)
                Image(systemName: "checkmark")
                    .font(.harcLabel.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(HarcSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: HarcSpacing.sm))
            .background(
                Color.primary.opacity(hoveredMicrophone == (uid ?? "") ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: HarcSpacing.sm)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredMicrophone = uid ?? ""
            } else if hoveredMicrophone == (uid ?? "") {
                hoveredMicrophone = nil
            }
        }
        .help(name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var systemDefaultLabel: String {
        if let name = bridge.systemDefaultMicrophoneName {
            return "System Default — \(name)"
        }
        return "System Default — unavailable"
    }

    private var unavailableSelectedUID: String? {
        guard let uid = bridge.microphoneSelection.deviceUID,
              !bridge.availableMicrophones.contains(where: { $0.uid == uid }) else {
            return nil
        }
        return uid
    }
}
