import SwiftUI
import HarcAudio

/// Shared microphone selector for Quick Capture, the Library record card, and
/// Recording settings. It deliberately includes an unavailable persisted route
/// so a dock disconnect never looks like Harc forgot the user's choice.
public struct MicrophonePickerControl: View {
    @ObservedObject private var bridge: HarcAppBridge
    private let showsLabel: Bool

    public init(bridge: HarcAppBridge, showsLabel: Bool = false) {
        self.bridge = bridge
        self.showsLabel = showsLabel
    }

    public var body: some View {
        Picker(selection: selectionBinding) {
            Text(systemDefaultLabel).tag("")
            ForEach(bridge.availableMicrophones) { device in
                Text(device.name).tag(device.uid)
            }
            if let uid = unavailableSelectedUID {
                Text("\(bridge.selectedMicrophoneName) — disconnected").tag(uid)
            }
        } label: {
            if showsLabel {
                Label("Microphone", systemImage: "mic")
            } else {
                EmptyView()
            }
        }
        .pickerStyle(.menu)
        .disabled(bridge.recordingState.isActiveOrPreparing)
        .accessibilityIdentifier("harc.microphonePicker")
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { bridge.microphoneSelection.deviceUID ?? "" },
            set: { bridge.onSelectMicrophone($0.isEmpty ? nil : $0) }
        )
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
