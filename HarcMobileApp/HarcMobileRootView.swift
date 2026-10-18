import AVFAudio
import HarcDomain
import Observation
import SwiftUI
import UIKit

struct HarcMobileRootView: View {
    private enum RootTab: Hashable {
        case record
        case library
        case search
    }

    @Environment(HarcMobileAppModel.self) private var model
    @State private var selectedTab: RootTab = .record
    @State private var showsLocalRecordings = false
    @State private var showsSetupAndSync = false
    @State private var captureAccessoryStartedAt: Date?
    @State private var libraryQuery = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: RootTab.record) {
                NavigationStack {
                    recordingView
                        .toolbar(.hidden, for: .navigationBar)
                }
            } label: {
                HarcMobileRecordTabLabel(
                    startedAt: model.captureCoordinator?.startedAt
                )
            }

            Tab(
                "Library",
                systemImage: "rectangle.stack",
                value: RootTab.library
            ) {
                NavigationStack {
                    libraryView
                        .navigationTitle("Library")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                hostPill
                            }
                        }
                }
            }

            Tab(value: RootTab.search, role: .search) {
                NavigationStack {
                    librarySearchTab
                        .navigationTitle("Search")
                }
                .accessibilityIdentifier(HarcMobileAccessibilityID.searchTab)
            }
        }
        .tint(recordTabTint)
        .accessibilityIdentifier(HarcMobileAccessibilityID.root)
        .tabViewBottomAccessory {
            if showsCaptureAccessory,
               let coordinator = model.captureCoordinator,
               let startedAt = captureAccessoryStartedAt {
                HarcMobileCaptureAccessory(
                    startedAt: startedAt,
                    title: captureAccessoryTitle(startedAt: startedAt),
                    isStopping: coordinator.state == .stopping,
                    openRecording: { selectedTab = .record },
                    stop: { coordinator.stop() }
                )
            }
        }
        .onChange(
            of: model.captureCoordinator?.state,
            initial: true
        ) { _, state in
            switch state {
            case .recording(let startedAt):
                captureAccessoryStartedAt = startedAt
            case .stopping:
                break
            default:
                captureAccessoryStartedAt = nil
            }
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
            model.transferCoordinator?.refreshLocalRecordings()
            model.transferCoordinator?.reconcileBackgroundUploads()
            model.libraryCoordinator?.refresh()
            model.hostHealthCoordinator?.startMonitoring()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didEnterBackgroundNotification
            )
        ) { _ in
            model.hostHealthCoordinator?.stopMonitoring()
        }
        .sheet(isPresented: $showsSetupAndSync) {
            HarcMobileSetupAndSyncView()
        }
    }

    private var hostPill: some View {
        HarcMobileHostPill(
            presentation: .make(
                status: model.hostHealthCoordinator?.status ?? .unpaired,
                hostName: adoptedHostName
            )
        ) {
            showsSetupAndSync = true
        }
    }

    private var rejectedCaptureMetadataWarning: some View {
        Label(
            "Some saved audio needs recovery. Harc kept the files on this iPhone. You can keep recording.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsCaptureAccessory: Bool {
        guard selectedTab != .record,
              let state = model.captureCoordinator?.state else {
            return false
        }
        switch state {
        case .recording, .stopping:
            return true
        default:
            return false
        }
    }

    private func captureAccessoryTitle(startedAt: Date) -> String {
        "Recording " + startedAt.formatted(
            date: .omitted,
            time: .shortened
        )
    }

    private var librarySearchTab: some View {
        List {
            Section {
                if let coordinator = model.libraryCoordinator {
                    if libraryQuery.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                        ContentUnavailableView(
                            "Search Library",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Search Host titles, tags, and transcripts."
                            )
                        )
                    } else {
                        librarySearchView(coordinator)
                    }
                } else {
                    ProgressView("Opening protected Host Library cache…")
                }
            } footer: {
                Text(
                    "Recordings still on this iPhone match by title only."
                )
            }
        }
        .searchable(
            text: $libraryQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Host titles, tags, and transcripts"
        )
        .task(id: libraryQuery) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                await model.libraryCoordinator?.search(libraryQuery)
            } catch {}
        }
    }

    private var libraryView: some View {
        List {
            if !model.rejectedCaptureMetadataFiles.isEmpty {
                Section { rejectedCaptureMetadataWarning }
            }
            Section { syncStatusLink }
            Section("On This iPhone") {
                if let transfer = model.transferCoordinator {
                    if let error = transfer.localRecordingsError {
                        Label(error, systemImage: "exclamationmark.triangle")
                    }
                    if transfer.localRecordings.isEmpty {
                        Text("Recordings saved on this iPhone appear here, even without a Host.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(transfer.localRecordings) { recording in
                        HarcMobileLocalRecordingRow(
                            recording: recording,
                            captureIsActive: model.captureCoordinator?.isRecording ?? false,
                            retryTransfer: transfer.retry(recordingUUID:),
                            transferRetryIsAvailable: transfer.isCodecQualifiedForTransfers
                        )
                    }
                } else {
                    Text("Unlock iPhone to open protected local recordings.")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("harc.mobile.library.local")

            Section("Host Library") {
                if let coordinator = model.libraryCoordinator {
                    if coordinator.recordings.isEmpty {
                        emptyLibraryView(coordinator)
                    } else {
                        libraryStateRow(coordinator)
                        if coordinator.pendingMutationCount > 0 {
                            Label(
                                "\(coordinator.pendingMutationCount) protected edit(s) waiting for Host",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .foregroundStyle(.secondary)
                        }
                        if !coordinator.conflicts.isEmpty {
                            Label(
                                "\(coordinator.conflicts.count) edit conflict(s) need review",
                                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                            )
                            .foregroundStyle(.orange)
                        }
                        ForEach(coordinator.recordings) { recording in
                            NavigationLink {
                                HarcMobileRecordingDetailView(
                                    coordinator: coordinator,
                                    summary: recording
                                )
                            } label: {
                                HarcMobileRecordingRow(recording: recording)
                            }
                        }
                    }
                } else {
                    ProgressView("Opening protected Host Library cache…")
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .refreshable {
            model.transferCoordinator?.refreshLocalRecordings()
            model.libraryCoordinator?.refresh()
        }
        .onAppear { model.transferCoordinator?.refreshLocalRecordings() }
    }

    private var syncStatus: HarcMobileSyncStatusPresentation {
        let transfer = model.transferCoordinator
        return .make(
            host: .init(model.hostHealthCoordinator?.status ?? .unpaired),
            transfer: transfer.map { .init($0.state) } ?? .preparing,
            codecQualified: transfer?.isCodecQualifiedForTransfers ?? false,
            pendingCount: transfer.map {
                HarcMobileCaptureStatusPresentation.effectivePendingCount(
                    pendingCount: $0.pendingCount,
                    localRecordings: $0.localRecordings
                )
            } ?? 0
        )
    }

    private var syncStatusLink: some View {
        NavigationLink {
            syncDetailView
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label("Sending to Mac", systemImage: "arrow.up.circle")
                    .font(.headline)
                Text("\(syncStatus.pendingCount) recordings waiting to transfer")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityLabel("Sync status")
        .accessibilityValue(
            "\(syncStatus.pendingCount) recordings waiting to transfer."
        )
        .accessibilityHint("Shows transfer availability, Host connection and Library status.")
        .accessibilityIdentifier(HarcMobileSyncAccessibilityID.libraryStatus)
    }

    private var syncDetailView: some View {
        HarcMobileSendingToMacView()
    }

    @ViewBuilder
    private func librarySearchView(
        _ coordinator: HarcMobileLibraryCoordinator
    ) -> some View {
        if coordinator.isSearching, coordinator.searchResults.isEmpty {
            ProgressView("Searching Host…")
        } else if coordinator.searchResults.isEmpty {
            ContentUnavailableView.search(text: libraryQuery)
        } else {
            Group {
                if let message = coordinator.searchMessage {
                    Label(message, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(coordinator.searchResults) { result in
                    NavigationLink {
                        HarcMobileRecordingDetailView(
                            coordinator: coordinator,
                            summary: result.recording
                        )
                    } label: {
                        HarcMobileLibrarySearchRow(result: result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyLibraryView(
        _ coordinator: HarcMobileLibraryCoordinator
    ) -> some View {
        switch coordinator.state {
        case .loadingCache, .refreshing:
            ProgressView("Syncing Library…")
        case .unpaired:
            ContentUnavailableView(
                "Pair a Host",
                systemImage: "macmini",
                description: Text(
                    "Pair locally to sync the Library view permitted by your Host."
                )
            )
        case .accessNotGranted:
            ContentUnavailableView(
                "Library access not granted",
                systemImage: "lock",
                description: Text(
                    "Pair again and approve the requested Library scopes on the Host. Existing recordings remain local."
                )
            )
        case .failed(let message), .offline(let message):
            ContentUnavailableView(
                "Library unavailable",
                systemImage: "wifi.slash",
                description: Text(message)
            )
        case .cancelled:
            ContentUnavailableView(
                "Refresh cancelled",
                systemImage: "arrow.clockwise",
                description: Text("Refresh Library to try again.")
            )
        case .ready:
            ContentUnavailableView(
                "No recordings yet",
                systemImage: "rectangle.stack",
                description: Text("The Host Library is synced and currently empty.")
            )
        }
    }

    @ViewBuilder
    private func libraryStateRow(
        _ coordinator: HarcMobileLibraryCoordinator
    ) -> some View {
        switch coordinator.state {
        case .refreshing:
            HStack { ProgressView(); Text("Refreshing from Host…") }
        case .cancelled:
            Label("Host Library refresh cancelled.", systemImage: "arrow.clockwise")
                .foregroundStyle(.secondary)
        case .offline(let message):
            Label(message, systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        case .accessNotGranted:
            Label(
                "Cached data only; current grant lacks Library access",
                systemImage: "lock"
            )
            .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        default:
            EmptyView()
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
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        recordHeader(captureState: coordinator.state)

                        Spacer(minLength: 24)

                        HarcMobileCaptureHeroView(
                            state: coordinator.state,
                            audioLevel: { coordinator.audioActivityLevel },
                            start: { Task { await coordinator.start() } },
                            stop: { coordinator.stop() },
                            reset: { coordinator.resetTerminalState() }
                        )

                        if recovered > 0 {
                            Label(
                                "Recovered \(recovered) durable recording\(recovered == 1 ? "" : "s")",
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(HarcMobilePalette.success)
                            .padding(.top, 12)
                        }

                        if coordinator.state == .idle,
                           let transfer = model.transferCoordinator {
                            let presentation =
                                HarcMobileCaptureStatusPresentation.transfer(
                                    state: transfer.state,
                                    pendingCount: transfer.pendingCount,
                                    localRecordings: transfer.localRecordings,
                                    hostName: adoptedHostName
                                )
                            if transferSummaryKind(transfer) == .caughtUp {
                                HarcMobileTransferSummaryView(
                                    kind: .caughtUp,
                                    presentation: presentation,
                                    action: {}
                                )
                                .padding(.top, 14)
                            }

                            Spacer(minLength: 24)

                            if transferSummaryKind(transfer) == .pending {
                                HarcMobileTransferSummaryView(
                                    kind: .pending,
                                    presentation: presentation,
                                    action: { showsLocalRecordings = true }
                                )
                            }
                        } else {
                            Spacer(minLength: 24)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .frame(
                        minHeight: geometry.size.height,
                        alignment: .top
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(Color(uiColor: .systemBackground))
            .refreshable {
                model.transferCoordinator?.refreshLocalRecordings()
                model.libraryCoordinator?.refresh()
                await model.hostHealthCoordinator?.refresh()
            }
            .sheet(isPresented: $showsLocalRecordings) {
                NavigationStack {
                    ScrollView {
                        if let transfer = model.transferCoordinator {
                            localRecordingsSection(
                                transfer,
                                captureIsActive: coordinator.isRecording
                            )
                            .padding()
                        }
                    }
                    .navigationTitle("On This iPhone")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsLocalRecordings = false }
                        }
                    }
                }
            }
        } else {
            ProgressView("Preparing recorder…")
        }
    }

    @ViewBuilder
    private func recordHeader(
        captureState: HarcMobileCaptureCoordinator.State
    ) -> some View {
        if case .recording = captureState {
            HarcMobileRecordingIndicator()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        } else {
            HStack(spacing: 16) {
                Text("Record")
                    .font(.title2.weight(.bold))
                Spacer(minLength: 8)
                hostPill
            }
        }
    }

    private func transferSummaryKind(
        _ coordinator: HarcMobileTransferCoordinator
    ) -> HarcMobileTransferSummaryKind {
        let pending = HarcMobileCaptureStatusPresentation
            .effectivePendingCount(
                pendingCount: coordinator.pendingCount,
                localRecordings: coordinator.localRecordings
            )
        if pending > 0 || coordinator.localRecordingsError != nil {
            return .pending
        }
        switch coordinator.state {
        case .idle, .uploaded:
            return .caughtUp
        case .encoding, .waitingForPairing, .connecting, .uploading,
             .backgroundScheduled, .codecQualificationRequired,
             .retryNeeded, .securityBlocked:
            return .pending
        }
    }

    private var adoptedHostName: String? {
        model.hostHealthCoordinator?.hostDisplayName
            ?? model.pairingCoordinator?.pairedHostDisplayName
    }

    private var recordTabTint: Color {
        if selectedTab == .record,
           model.captureCoordinator?.startedAt != nil {
            return HarcMobilePalette.coral
        }
        return HarcMobilePalette.action
    }

    private var localRecordingsDestination: some View {
        ScrollView {
            Group {
                if let transfer = model.transferCoordinator {
                    if transfer.localRecordings.isEmpty,
                       transfer.localRecordingsError == nil {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "iphone",
                            description: Text(
                                "Recordings saved on this iPhone appear here, even without a Host."
                            )
                        )
                        .accessibilityIdentifier("harc.mobile.local-recordings.empty")
                    } else {
                        localRecordingsSection(
                            transfer,
                            captureIsActive: model.captureCoordinator?.isRecording ?? false
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Local recordings unavailable",
                        systemImage: "lock",
                        description: Text("Unlock iPhone to open protected local recordings.")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("On This iPhone")
        .accessibilityIdentifier("harc.mobile.local-recordings")
    }

    @ViewBuilder
    private func localRecordingsSection(
        _ coordinator: HarcMobileTransferCoordinator,
        captureIsActive: Bool
    ) -> some View {
        if !coordinator.localRecordings.isEmpty
            || coordinator.localRecordingsError != nil {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text("On This iPhone")
                    .font(.title3.weight(.semibold))
                Text(
                    "Protected masters remain available here while Host transfer is unavailable."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let error = coordinator.localRecordingsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(coordinator.localRecordings) { recording in
                    HarcMobileLocalRecordingRow(
                        recording: recording,
                        captureIsActive: captureIsActive,
                        retryTransfer: coordinator.retry(recordingUUID:),
                        transferRetryIsAvailable: coordinator.isCodecQualifiedForTransfers
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct HarcMobileCaptureAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let startedAt: Date
    let title: String
    let isStopping: Bool
    let openRecording: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openRecording) {
                HStack(spacing: 10) {
                    HarcMobileLiveDot()
                    HarcMobileElapsedTime(startedAt: startedAt)
                        .foregroundStyle(HarcMobilePalette.coral)
                    if placement != .inline {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open active recording")
            .accessibilityIdentifier(
                HarcMobileAccessibilityID.recordingBanner
            )

            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(HarcMobilePalette.coral, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .accessibilityLabel("Stop recording")
            .accessibilityIdentifier(
                HarcMobileAccessibilityID.recordingAccessoryStop
            )
        }
        .padding(.leading, placement == .inline ? 8 : 12)
        .padding(.trailing, 4)
    }
}

private struct HarcMobileLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 24, paused: reduceMotion)
        ) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3.5
            let pulse = reduceMotion ? 0 : ((sin(phase) + 1) / 2)
            Circle()
                .fill(HarcMobilePalette.coral)
                .frame(width: 9, height: 9)
                .scaleEffect(0.9 + (pulse * 0.3))
                .opacity(0.75 + (pulse * 0.25))
        }
        .accessibilityHidden(true)
    }
}

struct HarcMobileLocalRecordingRow: View {
    let recording: HarcMobileLocalRecording
    let captureIsActive: Bool
    let retryTransfer: (UUID) -> Void
    let transferRetryIsAvailable: Bool

    @State private var audio: HarcMobileLocalRecordingAudioController
    @State private var showsExport = false

    init(
        recording: HarcMobileLocalRecording,
        captureIsActive: Bool,
        retryTransfer: @escaping (UUID) -> Void,
        transferRetryIsAvailable: Bool
    ) {
        self.recording = recording
        self.captureIsActive = captureIsActive
        self.retryTransfer = retryTransfer
        self.transferRetryIsAvailable = transferRetryIsAvailable
        _audio = State(
            initialValue: HarcMobileLocalRecordingAudioController(
                url: recording.masterFileURL
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.startedAt, format: .dateTime
                        .month(.abbreviated).day().hour().minute())
                        .font(.headline)
                    Text(Self.duration(recording.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                transferLabel
            }
            HStack {
                Button {
                    Task { await audio.playOrPause() }
                } label: {
                    switch audio.state {
                    case .loading:
                        ProgressView()
                    case .playing:
                        Label("Pause", systemImage: "pause.fill")
                    default:
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(captureIsActive)
                .accessibilityIdentifier("harc.mobile.local.play.\(recording.id)")

                Button("Export…", systemImage: "square.and.arrow.up") {
                    audio.stop()
                    showsExport = true
                }
                .buttonStyle(.bordered)
                .disabled(captureIsActive)
            }
            if captureIsActive {
                Text("Playback and export are paused while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let discontinuity = recording.discontinuities.last {
                Label(
                    Self.discontinuityText(discontinuity.reason),
                    systemImage: "waveform.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if case .failed(let message) = audio.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showsExport) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Export outside Harc", systemImage: "shield.lefthalf.filled")
                        .font(.title2.weight(.semibold))
                    Text(HarcMobileLocalRecording.exportDisclosure)
                        .accessibilityIdentifier(
                            HarcMobileAccessibilityID.exportDisclosure
                        )
                    ShareLink(item: recording.masterFileURL) {
                        Label("Choose Export Destination", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        HarcMobileAccessibilityID.exportShare
                    )
                    Spacer()
                }
                .padding()
                .navigationTitle("Export Recording")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsExport = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onDisappear { audio.stop() }
    }

    @ViewBuilder
    private var transferLabel: some View {
        switch recording.transferState {
        case .localOnly:
            Label("Local", systemImage: "iphone")
                .foregroundStyle(.secondary)
        case .transferring:
            Label("Transferring", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .retryNeeded where !transferRetryIsAvailable:
            Label("Waiting", systemImage: "iphone")
        case .securityBlocked where !transferRetryIsAvailable:
            Label("Host access needs review", systemImage: "lock")
        case .retryNeeded:
            Button("Retry", systemImage: "arrow.clockwise") {
                retryTransfer(recording.id)
            }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
        case .securityBlocked:
            Button("Review & Retry", systemImage: "lock.open") {
                retryTransfer(recording.id)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        case .committed:
            Label("On Host", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func discontinuityText(
        _ reason: CaptureDiscontinuityReason
    ) -> String {
        switch reason {
        case .interruptionBegan:
            "Recording ended after an audio interruption"
        case .interruptionEnded:
            "Recording contains an interruption boundary"
        case .routeChanged:
            "Recording ended after the microphone route changed"
        case .engineConfigurationChanged:
            "Recording ended after the audio configuration changed"
        case .mediaServicesLost:
            "Recording ended when iOS audio services became unavailable"
        case .mediaServicesReset:
            "Recording ended after iOS reset audio services"
        case .writerFailure:
            "Recording ended after a local writer failure"
        case .bufferOverrun:
            "Recording contains a visible audio gap"
        case .recovery:
            "Recording was recovered through its last durable frame"
        }
    }
}

private struct HarcMobileRecordingRow: View {
    let recording: LibraryRecordingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recording.title ?? recording.suggestedTitle ?? "Untitled Recording")
                    .font(.headline)
                    .lineLimit(2)
                if recording.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(recording.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(
                    recording.processing.state.rawValue,
                    systemImage: processingSymbol
                )
                if !recording.tags.isEmpty {
                    Text(recording.tags.prefix(3).joined(separator: " · "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var processingSymbol: String {
        switch recording.processing.state {
        case .ready: "checkmark.circle"
        case .failedRecoverable, .degraded: "exclamationmark.triangle"
        case .pending, .transcribing, .projecting: "clock"
        }
    }
}

private struct HarcMobileLibrarySearchRow: View {
    let result: HarcMobileLibraryCoordinator.SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HarcMobileRecordingRow(recording: result.recording)
            if let snippet = result.snippets.first, !snippet.isEmpty {
                Text(snippet.replacingOccurrences(of: "<mark>", with: "")
                    .replacingOccurrences(of: "</mark>", with: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct HarcMobileRecordingDetailView: View {
    let coordinator: HarcMobileLibraryCoordinator
    let summary: LibraryRecordingSummary

    @State private var detail: LibraryRecordingDetail?
    @State private var errorMessage: String?
    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    @State private var notesDraft = ""
    @State private var newSpeakerIndex = ""
    @State private var newSpeakerName = ""
    @State private var mutationMessage: String?
    @State private var isSavingMetadata = false
    @State private var audioController: HarcMobileRecordingAudioController

    init(
        coordinator: HarcMobileLibraryCoordinator,
        summary: LibraryRecordingSummary
    ) {
        self.coordinator = coordinator
        self.summary = summary
        _audioController = State(
            initialValue: HarcMobileRecordingAudioController(
                coordinator: coordinator,
                summary: summary
            )
        )
    }

    var body: some View {
        Group {
            if let detail {
                List {
                    if detail.summary.canonicalAudio.availability == .available {
                        Section("Audio") {
                            Button {
                                Task { await audioController.playOrPause() }
                            } label: {
                                audioPlaybackLabel
                            }
                            .disabled(audioController.state == .downloading)
                            if case .failed(let message) = audioController.state {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    Section("Status") {
                        LabeledContent("Processing", value: detail.summary.processing.state.rawValue)
                        LabeledContent("Projection", value: detail.summary.projection.state.rawValue)
                        LabeledContent(
                            "Host audio",
                            value: detail.summary.canonicalAudio.availability
                                == .available
                                ? "Durable and verified"
                                : "Pending canonical audio"
                        )
                        LabeledContent("Revision", value: String(detail.summary.revision.rawValue))
                    }
                    if detail.captureNeedsReview {
                        Section("Capture quality") {
                            Label("Some audio may be missing. Review this recording before relying on it.", systemImage: "exclamationmark.triangle")
                                .accessibilityIdentifier("harc.mobile.captureIntegrityWarning")
                        }
                    }
                    if !detail.discontinuities.isEmpty {
                        Section("Capture interruptions") {
                            ForEach(
                                Array(detail.discontinuities.enumerated()),
                                id: \.offset
                            ) { _, discontinuity in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(
                                        Self.discontinuityText(
                                            discontinuity.reason
                                        ),
                                        systemImage:
                                            "waveform.badge.exclamationmark"
                                    )
                                    Text(
                                        discontinuity.wallTime,
                                        format: .dateTime
                                            .month().day().hour().minute()
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if let routeChange = Self.routeChangeText(
                                        discontinuity
                                    ) {
                                        Text(routeChange)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section("Speakers") {
                        if detail.speakerLabels.isEmpty {
                            Text("No speaker labels are available yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(
                                detail.speakerLabels,
                                id: \.speakerIndex
                            ) { label in
                                HarcMobileSpeakerLabelEditor(
                                    label: label,
                                    profiles: coordinator.recognitionPack?.profiles ?? [],
                                    isSaving: isSavingMetadata,
                                    onSave: { displayName in
                                    submitMetadata(
                                        .setSpeakerLabel(
                                            index: label.speakerIndex,
                                            displayName: displayName
                                        )
                                    )
                                    },
                                    onAssign: { personID in
                                        submitMetadata(
                                            .assignSpeakerIdentity(
                                                index: label.speakerIndex,
                                                personID: personID
                                            )
                                        )
                                    }
                                )
                                .id(
                                    "\(label.speakerIndex)-\(label.displayName)-\(label.personID?.description ?? "unlinked")-\(coordinator.recognitionPack?.revision.rawValue ?? 0)"
                                )
                            }
                        }
                        TextField(
                            "Speaker index",
                            text: $newSpeakerIndex
                        )
                        .keyboardType(.numberPad)
                        TextField(
                            "Speaker display name",
                            text: $newSpeakerName
                        )
                        Button("Add speaker label") {
                            guard let index = UInt32(newSpeakerIndex) else {
                                return
                            }
                            let displayName = newSpeakerName
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                            submitMetadata(
                                .setSpeakerLabel(
                                    index: index,
                                    displayName: displayName
                                )
                            )
                            newSpeakerIndex = ""
                            newSpeakerName = ""
                        }
                        .disabled(
                            UInt32(newSpeakerIndex) == nil
                                || newSpeakerName.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                                || isSavingMetadata
                        )
                    }
                    Section("Edit on Host") {
                        TextField("Title", text: $titleDraft)
                        Button("Save title") {
                            let trimmed = titleDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            submitMetadata(
                                .setTitle(trimmed.isEmpty ? nil : titleDraft)
                            )
                        }
                        TextField(
                            "Tags separated by commas",
                            text: $tagsDraft
                        )
                        Button("Replace tags") {
                            submitMetadata(
                                .replaceTags(tagsDraft.split(separator: ",").map {
                                    String($0)
                                })
                            )
                        }
                        TextEditor(text: $notesDraft)
                            .frame(minHeight: 90)
                        Button("Save notes") {
                            let trimmed = notesDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            submitMetadata(
                                .setNotesMarkdown(
                                    trimmed.isEmpty ? nil : notesDraft
                                )
                            )
                        }
                        Button(
                            detail.summary.pinned
                                ? "Unpin recording"
                                : "Pin recording"
                        ) {
                            submitMetadata(
                                .setPinned(!detail.summary.pinned)
                            )
                        }
                        .disabled(isSavingMetadata)
                        if isSavingMetadata {
                            ProgressView("Signing and sending…")
                        }
                        if let mutationMessage {
                            Text(mutationMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let visibleConflicts = coordinator.conflicts.filter {
                        $0.canonicalRecordingID == summary.canonicalID
                    }
                    if !visibleConflicts.isEmpty {
                        Section("Edit conflicts") {
                            ForEach(visibleConflicts, id: \.conflictID) { conflict in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(
                                        "The Host advanced from revision \(conflict.expectedRevision.rawValue) to \(conflict.currentRevision.rawValue)."
                                    )
                                    .font(.footnote)
                                    Button("Use Host value") {
                                        do {
                                            try coordinator.acceptHostValue(
                                                for: conflict
                                            )
                                            mutationMessage =
                                                "Conflict resolved with the Host value."
                                            Task { await loadDetail() }
                                        } catch {
                                            mutationMessage = error.localizedDescription
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let transcript = detail.transcriptText,
                       !transcript.isEmpty {
                        Section("Transcript") {
                            Text(
                                SpeakerTranscriptLabelProjector.project(
                                    transcript,
                                    labels: detail.speakerLabels
                                )
                            )
                                .textSelection(.enabled)
                        }
                    }
                    if let generatedSummary = detail.summaryMarkdown,
                       !generatedSummary.isEmpty {
                        Section("Summary") {
                            Text(generatedSummary)
                                .textSelection(.enabled)
                        }
                    }
                    if let actionItems = detail.actionItemsMarkdown,
                       !actionItems.isEmpty {
                        Section("Action Items") {
                            Text(actionItems)
                                .textSelection(.enabled)
                        }
                    }
                    if let notes = detail.notesMarkdown, !notes.isEmpty {
                        Section("Notes") {
                            Text(notes)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Detail unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading from Host…")
            }
        }
        .navigationTitle(summary.title ?? summary.suggestedTitle ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: summary.canonicalID) {
            await loadDetail()
        }
        .onDisappear { audioController.stopAndRelease() }
    }

    private func submitMetadata(_ mutation: HarcMobileMetadataMutation) {
        guard let current = detail?.summary,
              !isSavingMetadata else { return }
        isSavingMetadata = true
        mutationMessage = nil
        Task {
            defer { isSavingMetadata = false }
            do {
                let outcome = try await coordinator.submitMetadataMutation(
                    summary: current,
                    mutation: mutation
                )
                switch outcome {
                case .applied:
                    mutationMessage = "Saved on Host."
                    await loadDetail()
                case .queuedOffline:
                    mutationMessage =
                        "Saved safely on this iPhone; it will retry when the Host is online."
                case .conflict:
                    mutationMessage =
                        "The Host has a newer revision. Review the conflict below."
                }
            } catch {
                mutationMessage = error.localizedDescription
            }
        }
    }

    private func loadDetail() async {
        do {
            let loaded = try await coordinator.recordingDetail(
                canonicalID: summary.canonicalID
            )
            detail = loaded
            titleDraft = loaded.summary.title ?? ""
            tagsDraft = loaded.summary.tags.joined(separator: ", ")
            notesDraft = loaded.notesMarkdown ?? ""
            errorMessage = nil
        } catch {
            if detail == nil { errorMessage = error.localizedDescription }
        }
    }

    private static func discontinuityText(
        _ reason: CaptureDiscontinuityReason
    ) -> String {
        switch reason {
        case .interruptionBegan: "Audio interruption began"
        case .interruptionEnded: "Audio interruption ended"
        case .routeChanged: "Microphone route changed"
        case .engineConfigurationChanged: "Audio configuration changed"
        case .mediaServicesLost: "iOS audio services were lost"
        case .mediaServicesReset: "iOS audio services reset"
        case .writerFailure: "Local audio writer failed"
        case .bufferOverrun: "Audio buffer overrun"
        case .recovery: "Durable recording recovery"
        }
    }

    private static func routeChangeText(
        _ discontinuity: CaptureDiscontinuity
    ) -> String? {
        let oldName = discontinuity.oldRoute?.name
            ?? discontinuity.oldRoute?.identifier
        let newName = discontinuity.newRoute?.name
            ?? discontinuity.newRoute?.identifier
        return switch (oldName, newName) {
        case (.some(let old), .some(let new)):
            "\(old) → \(new)"
        case (.some(let old), .none):
            "Previous route: \(old)"
        case (.none, .some(let new)):
            "New route: \(new)"
        case (.none, .none):
            nil
        }
    }

    @ViewBuilder
    private var audioPlaybackLabel: some View {
        switch audioController.state {
        case .idle:
            Label("Play canonical audio", systemImage: "play.fill")
        case .downloading:
            HStack {
                ProgressView()
                Text("Downloading verified audio…")
            }
        case .playing:
            Label("Pause", systemImage: "pause.fill")
        case .paused:
            Label("Resume", systemImage: "play.fill")
        case .failed:
            Label("Try audio again", systemImage: "arrow.clockwise")
        }
    }
}

private struct HarcMobileSpeakerLabelEditor: View {
    let label: SpeakerLabel
    let profiles: [SpeakerIdentityProfile]
    let isSaving: Bool
    let onSave: (String?) -> Void
    let onAssign: (PersonID?) -> Void

    @State private var displayName: String

    init(
        label: SpeakerLabel,
        profiles: [SpeakerIdentityProfile],
        isSaving: Bool,
        onSave: @escaping (String?) -> Void,
        onAssign: @escaping (PersonID?) -> Void
    ) {
        self.label = label
        self.profiles = profiles
        self.isSaving = isSaving
        self.onSave = onSave
        self.onAssign = onAssign
        _displayName = State(initialValue: label.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speaker \(label.speakerIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $displayName)
            if !profiles.isEmpty {
                Menu {
                    if label.personID != nil {
                        Button("Remove Host identity", role: .destructive) {
                            onAssign(nil)
                        }
                        Divider()
                    }
                    ForEach(profiles) { profile in
                        Button(profile.displayName) {
                            onAssign(profile.id)
                        }
                    }
                } label: {
                    Label(
                        label.personID == nil
                            ? "Link to a Host person"
                            : "Host identity: \(label.displayName)",
                        systemImage: label.personID == nil
                            ? "person.crop.circle.badge.plus"
                            : "person.crop.circle.badge.checkmark"
                    )
                }
            }
            HStack {
                Button("Save") {
                    let trimmed = displayName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    onSave(trimmed.isEmpty ? nil : trimmed)
                }
                Button("Remove", role: .destructive) {
                    onSave(nil)
                }
            }
            .disabled(isSaving)
        }
    }
}
