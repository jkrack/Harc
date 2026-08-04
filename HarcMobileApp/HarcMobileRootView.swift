import HarcDomain
import SwiftUI
import UIKit

struct HarcMobileRootView: View {
    @Environment(HarcMobileAppModel.self) private var model
    @State private var showsPairingScanner = false

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
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.transferCoordinator?.retryPending()
        }
        .sheet(isPresented: $showsPairingScanner) {
            NavigationStack {
                HarcPairingScannerView(
                    onCode: { code in
                        showsPairingScanner = false
                        Task {
                            await model.pairingCoordinator?.begin(
                                scannedURI: code
                            )
                        }
                    },
                    onFailure: { message in
                        showsPairingScanner = false
                        model.pairingCoordinator?.scannerFailed(message)
                    }
                )
                .ignoresSafeArea()
                .navigationTitle("Scan Host Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsPairingScanner = false }
                    }
                }
            }
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
                if let transfer = model.transferCoordinator {
                    transferStatus(transfer)
                }
            }
            .padding()
        } else {
            ProgressView("Preparing recorder…")
        }
    }

    @ViewBuilder
    private func transferStatus(
        _ coordinator: HarcMobileTransferCoordinator
    ) -> some View {
        switch coordinator.state {
        case .idle:
            if coordinator.pendingCount > 0 {
                Label(
                    "\(coordinator.pendingCount) recording(s) retained locally",
                    systemImage: "externaldrive"
                )
                .foregroundStyle(.secondary)
            }
        case .encoding:
            ProgressView("Preparing lossless transfer chunks…")
        case .waitingForPairing(let pending):
            Label(
                "\(pending) recording(s) waiting for a Host",
                systemImage: "macmini"
            )
            .foregroundStyle(.secondary)
        case .connecting:
            ProgressView("Connecting securely to Host…")
        case .uploading:
            ProgressView("Uploading lossless audio to Host…")
        case .uploaded:
            Label(
                "Verified by Host and saved locally",
                systemImage: "checkmark.icloud"
            )
            .foregroundStyle(.green)
        case .codecQualificationRequired:
            VStack(spacing: 8) {
                Label(
                    "Lossless codec qualification required",
                    systemImage: "iphone.gen3.radiowaves.left.and.right"
                )
                .foregroundStyle(.orange)
                Text(
                    "This build will not upload raw audio. CAF+ALAC versus FLAC must pass the physical-iPhone release gate."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        case .retryNeeded(_, let message):
            VStack(spacing: 8) {
                Label(
                    "Saved locally; Host transfer will retry",
                    systemImage: "arrow.clockwise.icloud"
                )
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry Host Transfer") {
                    coordinator.retryPending()
                }
                .buttonStyle(.bordered)
            }
        case .securityBlocked(_, let message):
            VStack(spacing: 8) {
                Label(
                    "Transfer blocked for security",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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
            hostReadyView(deviceID: deviceID)
        default:
            ContentUnavailableView(
                "Finish local setup first",
                systemImage: "hourglass"
            )
        }
    }

    @ViewBuilder
    private func hostReadyView(deviceID: DeviceID) -> some View {
        if let coordinator = model.pairingCoordinator {
            List {
                Section("This iPhone") {
                    LabeledContent("Device ID") {
                        Text(String(deviceID.description.prefix(16)) + "…")
                            .font(.caption.monospaced())
                    }
                }
                pairingContent(coordinator)
            }
        } else {
            ProgressView("Preparing secure pairing…")
        }
    }

    @ViewBuilder
    private func pairingContent(
        _ coordinator: HarcMobilePairingCoordinator
    ) -> some View {
        switch coordinator.state {
        case .unpaired:
            Section {
                Button("Scan Host Pairing Code", systemImage: "qrcode.viewfinder") {
                    showsPairingScanner = true
                }
            } footer: {
                Text("The short-lived code pins the Host identity and local TLS route. No cloud account is used.")
            }
        case .connecting:
            Section {
                HStack {
                    ProgressView()
                    Text("Verifying Host and proving this iPhone…")
                }
            }
        case .compareWords(let host, let phrase, let expiresAt):
            Section("Compare on \(host)") {
                Text(phrase)
                    .font(.title2.weight(.semibold).monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Security words: \(phrase)")
                Text("Code expires \(expiresAt, style: .relative).")
                    .foregroundStyle(.secondary)
                Button("These Four Words Match", systemImage: "checkmark.shield") {
                    Task { await coordinator.confirmWordsMatch() }
                }
                .buttonStyle(.borderedProminent)
                Button("Words Do Not Match", role: .destructive) {
                    Task { await coordinator.wordsDoNotMatch() }
                }
            }
        case .awaitingHostApproval(let host, let phrase):
            Section("Waiting for \(host)") {
                HStack {
                    ProgressView()
                    Text("Approve this iPhone on the Host computer.")
                }
                LabeledContent("Security words", value: phrase)
            }
        case .paired(let host):
            Section {
                Label(host, systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Button("Pair a Different Host") {
                    coordinator.beginReplacement()
                    showsPairingScanner = true
                }
            } header: {
                Text("Adopted Host")
            } footer: {
                Text("Reconnects revalidate the signed Host transport and device grant before opening a session.")
            }
        case .failed(let message):
            Section("Pairing Failed") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") {
                    coordinator.resetFailure()
                    showsPairingScanner = true
                }
            }
        }
    }
}
