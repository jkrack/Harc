import SwiftUI
import HarcStore

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var vm: RecordingsViewModel

    let onToggle: () -> Void
    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void
    let onOpenLibrary: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
        self.onOpenLibrary = onOpenLibrary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            footer
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
        .background(.thickMaterial)
    }

    private var footer: some View {
        HStack(spacing: HarcDesign.Space.md) {
            footerButton(label: "Settings", systemImage: "gearshape", action: onOpenSettings)
            footerButton(label: "Library",  systemImage: "books.vertical", action: onOpenLibrary)
            Spacer()
        }
    }

    private func footerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HarcDesign.Space.xxs) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurface)
        }
        .buttonStyle(.plain)
    }
}
