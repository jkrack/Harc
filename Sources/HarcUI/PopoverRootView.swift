import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var index: RecordingsIndex

    let onToggle: () -> Void
    let onOpen: (RecordingEntry) -> Void
    let onOpenSettings: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (RecordingEntry) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle, onOpenSettings: onOpenSettings)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
    }
}
