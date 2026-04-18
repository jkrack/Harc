import SwiftUI

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState

    /// Closure AppDelegate wires in; called when user hits Start or Stop.
    let onToggle: () -> Void

    public init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(spacing: HarcDesign.Space.md) {
            Text("Harc")
                .font(HarcDesign.Font.titleLg)
                .foregroundStyle(Color.harcOnSurface)

            Button(action: onToggle) {
                Text(state.isRecording ? "Stop Recording" : "Start Recording")
                    .font(HarcDesign.Font.titleSm)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(state.isRecording ? AnyShapeStyle(Color.harcError) : AnyShapeStyle(HarcDesign.primaryGradient))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 360)
    }
}
