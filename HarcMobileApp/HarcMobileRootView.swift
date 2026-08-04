import HarcDomain
import SwiftUI
import UIKit

struct HarcMobileRootView: View {
    @Environment(HarcMobileAppModel.self) private var model

    var body: some View {
        TabView {
            NavigationStack {
                recordingView
                    .navigationTitle("Record")
            }
            .tabItem { Label("Record", systemImage: "waveform") }

            NavigationStack {
                ContentUnavailableView(
                    "No synced recordings yet",
                    systemImage: "rectangle.stack",
                    description: Text(
                        "Pair a host to sync receipts, processing status, and your permitted library view."
                    )
                )
                .navigationTitle("Library")
            }
            .tabItem { Label("Library", systemImage: "rectangle.stack") }

            NavigationStack {
                hostView
                    .navigationTitle("Host")
            }
            .tabItem { Label("Host", systemImage: "macmini") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            captureBanner
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            Task { await model.retryAfterProtectedDataBecomesAvailable() }
        }
    }

    @ViewBuilder
    private var recordingView: some View {
        switch model.readiness {
        case .starting:
            ProgressView("Preparing protected local recording…")
        case .ready(_, let recovered):
            readyRecordingView(recovered: recovered)
        case .protectedDataUnavailable:
            ContentUnavailableView(
                "Unlock iPhone to recover recordings",
                systemImage: "lock.fill",
                description: Text("Harc will not alter protected capture state before first unlock.")
            )
        case .keyLoss:
            ContentUnavailableView(
                "Device identity needs repair",
                systemImage: "key.slash",
                description: Text("Harc found prior client state but not its device-only signing key. Existing recordings remain local.")
            )
        case .failed(let message):
            ContentUnavailableView(
                "Local recording unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    @ViewBuilder
    private func readyRecordingView(recovered: Int) -> some View {
        if let coordinator = model.captureCoordinator {
            VStack(spacing: 24) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 82))
                    .foregroundStyle(.tint)
                captureStatus(coordinator)
                if recovered > 0 {
                    Label(
                        "Recovered \(recovered) durable recording\(recovered == 1 ? "" : "s")",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.green)
                }
                captureControl(coordinator)
            }
            .padding()
        } else {
            ProgressView("Preparing recorder…")
        }
    }

    @ViewBuilder
    private func captureStatus(
        _ coordinator: HarcMobileCaptureCoordinator
    ) -> some View {
        switch coordinator.state {
        case .idle:
            Text("Ready to record locally")
                .font(.title2.weight(.semibold))
            Text("Recording never waits for a host or network connection.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .requestingPermission:
            ProgressView("Waiting for microphone permission…")
        case .starting:
            ProgressView("Starting protected recording…")
        case .recording(let startedAt):
            Text("Recording")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            elapsedTime(since: startedAt)
        case .stopping:
            ProgressView("Saving durable recording…")
        case .saved:
            Label("Saved locally", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
        case .failed(let message):
            Text("Recording ended")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func captureControl(
        _ coordinator: HarcMobileCaptureCoordinator
    ) -> some View {
        switch coordinator.state {
        case .idle:
            Button("Start Recording", systemImage: "mic.fill") {
                Task { await coordinator.start() }
            }
            .buttonStyle(.borderedProminent)
        case .recording:
            Button("Stop Recording", systemImage: "stop.fill") {
                coordinator.stop()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .saved, .failed:
            Button("Record Again") { coordinator.resetTerminalState() }
                .buttonStyle(.borderedProminent)
        case .requestingPermission, .starting, .stopping:
            EmptyView()
        }
    }

    @ViewBuilder
    private var captureBanner: some View {
        if let coordinator = model.captureCoordinator {
            switch coordinator.state {
            case .recording(let startedAt):
                HStack(spacing: 12) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("Recording")
                        .font(.headline)
                    Spacer()
                    elapsedTime(since: startedAt)
                    Button("Stop") { coordinator.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            case .stopping:
                HStack {
                    ProgressView()
                    Text("Saving recording…")
                    Spacer()
                }
                .padding()
                .background(.bar)
            default:
                EmptyView()
            }
        }
    }

    private func elapsedTime(since start: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsedText(from: start, to: context.date))
                .font(.body.monospacedDigit())
                .accessibilityLabel("Recording duration")
        }
    }

    private static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var hostView: some View {
        switch model.readiness {
        case .ready(let deviceID, _):
            List {
                Section("This iPhone") {
                    LabeledContent("Device ID") {
                        Text(String(deviceID.description.prefix(16)) + "…")
                            .font(.caption.monospaced())
                    }
                }
                Section {
                    Button("Scan Host Pairing Code") {}
                        .disabled(true)
                } footer: {
                    Text("Pairing will compare four security words and still requires approval on the Host Mac.")
                }
            }
        default:
            ContentUnavailableView(
                "Finish local setup first",
                systemImage: "hourglass"
            )
        }
    }
}
