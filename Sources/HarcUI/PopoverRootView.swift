import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState

    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 360)
    }
}
