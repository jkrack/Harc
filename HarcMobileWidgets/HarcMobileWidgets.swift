import ActivityKit
import AppIntents
import HarcPresenceUI
import SwiftUI
import WidgetKit

@main
struct HarcMobileWidgetBundle: WidgetBundle {
    var body: some Widget { HarcRecordingActivityWidget() }
}

struct HarcRecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HarcRecordingActivityAttributes.self) { context in
            HStack(spacing: 16) {
                presence(context, size: .compact)
                VStack(alignment: .leading, spacing: 6) {
                    clock(context)
                        .font(.system(.largeTitle, design: .rounded, weight: .light))
                    Text(context.isStale ? "Open Harc to check recording" : context.state.phase)
                        .font(.headline)
                    Label(context.state.durableAudioSeconds > 0
                          ? "\(context.state.durableAudioSeconds / 60):\(String(format: "%02d", context.state.durableAudioSeconds % 60)) audio saved"
                          : "Preparing first save", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stopButton(context)
            }
            .padding(20)
            .activityBackgroundTint(Color(red: 0.10, green: 0.13, blue: 0.25))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    presence(context, size: .compact)
                }
                DynamicIslandExpandedRegion(.trailing) { stopButton(context) }
                DynamicIslandExpandedRegion(.center) {
                    clock(context).font(.system(.title2, design: .rounded))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open Harc to check recording" : "Recording on this iPhone")
                        .font(.caption)
                }
            } compactLeading: {
                presence(context, size: .mini)
            } compactTrailing: {
                clock(context).monospacedDigit().frame(maxWidth: 60)
            } minimal: {
                presence(context, size: .mini)
            }
        }
    }

    private func presence(
        _ context: ActivityViewContext<HarcRecordingActivityAttributes>,
        size: HarcPresenceSize
    ) -> some View {
        // Widget snapshots cannot sustain the in-app animation cadence.
        HarcPresenceBlob(state: context.isStale ? .attention : .recording,
                         size: size, showsSymbol: false, animates: false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func clock(_ context: ActivityViewContext<HarcRecordingActivityAttributes>) -> some View {
        if context.isStale {
            Text("Check Harc")
        } else {
            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        }
    }

    private func stopButton(_ context: ActivityViewContext<HarcRecordingActivityAttributes>) -> some View {
        Button(intent: StopHarcRecordingIntent(captureID: context.attributes.captureID)) {
            Image(systemName: "stop.fill")
                .font(.title3)
                .padding(14)
                .background(.red, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop and save recording")
    }
}
