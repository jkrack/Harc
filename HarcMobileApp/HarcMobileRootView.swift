import AVFAudio
import HarcDomain
import HarcPresenceUI
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab: RootTab = .record
    @State private var showsLocalRecordings = false
    @State private var showsSetupAndSync = false
    @State private var captureAccessoryStartedAt: Date?
    @State private var libraryQuery = ""
    @State private var libraryDay: Date?
    @ScaledMetric(relativeTo: .body) private var daySummaryTextSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var dayAxisTextSize: CGFloat = 14

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
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { hostPill }
                        }
                }
                .accessibilityIdentifier(HarcMobileAccessibilityID.searchTab)
            }
        }
        .tint(recordTabTint)
        .accessibilityIdentifier(HarcMobileAccessibilityID.root)
        .harcMobileCaptureAccessory(isEnabled: showsCaptureAccessory) {
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
                            "Find a moment",
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
                    "Recordings only on this iPhone are matched by title until they reach your Mac."
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background { HarcTideBackground() }
        .searchable(
            text: $libraryQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search meetings and transcripts"
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
            libraryDayPicker
                .listRowBackground(Color.clear)
            libraryTimeline
                .listRowBackground(Color.clear)
            if !model.rejectedCaptureMetadataFiles.isEmpty {
                Section { rejectedCaptureMetadataWarning }
            }
            if let attention = libraryAttention {
                Section {
                    NavigationLink {
                        HarcMobileSendingToMacView(setupDestination: .sheet)
                    } label: {
                        Label(
                            attention.title(macName: adoptedHostName ?? "your Mac"),
                            systemImage: attention.isSecurityBlocked
                                ? "lock.trianglebadge.exclamationmark"
                                : "arrow.up.circle"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            attention.isSecurityBlocked
                                ? Color.orange : Color.primary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier(
                        HarcMobileAccessibilityID.libraryAttention
                    )
                }
            }

            if let error = model.transferCoordinator?.localRecordingsError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if !unifiedLibraryGroups.isEmpty, showsLibraryRefreshStatus {
                Section("Mac Library") { libraryRefreshStatus }
            }

            if unifiedLibraryGroups.isEmpty {
                Section { unifiedLibraryEmptyState }
            } else {
                ForEach(unifiedLibraryGroups.filter { libraryDay == nil || $0.day == libraryDay }) { group in
                    Section(group.title) {
                        ForEach(group.recordings) { recording in
                            unifiedLibraryRow(recording)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { HarcTideBackground() }
        .accessibilityIdentifier("harc.mobile.library.local")
        .tabBarMinimizeBehavior(.onScrollDown)
        .refreshable {
            model.transferCoordinator?.refreshLocalRecordings()
            model.libraryCoordinator?.refresh()
        }
        .onAppear { model.transferCoordinator?.refreshLocalRecordings() }
        .onChange(of: model.captureCoordinator?.state) { previous, current in
            guard previous == .stopping, current == .idle else { return }
            model.transferCoordinator?.refreshLocalRecordings()
        }
    }

    private var libraryTimeline: some View {
        let day = libraryDay ?? Date.now
        let recordings = unifiedLibraryGroups.flatMap(\.recordings).filter {
            Calendar.current.isDate($0.startedAt, inSameDayAs: day)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(recordings.count) recordings")
                    .font(.caption)
            }
            HarcTideDayTimeline(intervals: recordings.map {
                DateInterval(start: $0.startedAt,
                             duration: libraryDuration($0))
            }, day: day)
            .frame(height: 64)
        }
        .padding(14)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    private var libraryDayPicker: some View {
        let days = Array(Set(unifiedLibraryGroups.flatMap(\.recordings).map {
            Calendar.current.startOfDay(for: $0.startedAt)
        })).sorted(by: >)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("All") { libraryDay = nil }
                    .buttonStyle(.bordered)
                    .tint(libraryDay == nil ? HarcMobilePalette.action : .secondary)
                ForEach(days, id: \.self) { day in
                    Button { libraryDay = day } label: {
                        VStack(spacing: 4) {
                            Text(day, format: .dateTime.weekday(.abbreviated))
                                .font(.caption)
                            Text(day, format: .dateTime.day())
                                .font(.system(.headline, design: .rounded))
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(libraryDay == day ? HarcMobilePalette.action : .secondary)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(libraryDay == day ? .isSelected : [])
                }
            }
        }
    }

    private func libraryDuration(_ item: HarcMobileUnifiedLibraryItem) -> TimeInterval {
        switch item {
        case .local(let recording): max(0, recording.duration)
        case .host(let recording): Double(recording.canonicalAudio.totalFrames ?? 0) / 16_000
        }
    }

    private var unifiedLibraryGroups: [HarcMobileUnifiedLibraryGroup] {
        HarcMobileUnifiedLibrary.groups(
            local: model.transferCoordinator?.localRecordings ?? [],
            host: model.libraryCoordinator?.recordings ?? []
        )
    }

    private var libraryAttention: HarcMobileLibraryAttention? {
        let transfer = model.transferCoordinator
        let securityBlocked = transfer?.localRecordings.contains {
            $0.transferState == .securityBlocked
        } == true || {
            guard let state = transfer?.state else { return false }
            if case .securityBlocked = state { return true }
            return false
        }()
        let offline: Bool = {
            guard let coordinator = model.libraryCoordinator,
                  !coordinator.recordings.isEmpty else { return false }
            return switch coordinator.state {
            case .offline, .failed, .cancelled: true
            default: false
            }
        }()
        return HarcMobileLibraryAttention.make(
            securityBlocked: securityBlocked,
            conflictCount: model.libraryCoordinator?.conflicts.count ?? 0,
            pendingCount: syncStatus.pendingCount,
            libraryIsOffline: offline
        )
    }

    private var showsLibraryRefreshStatus: Bool {
        if let state = model.libraryCoordinator?.state, case .ready = state { return false }
        return true
    }

    private var libraryRefreshStatus: some View {
        HarcMobileLibraryRefreshStatusView(
            state: model.libraryCoordinator?.state ?? .loadingCache,
            hasRows: !(model.libraryCoordinator?.recordings.isEmpty ?? true),
            refreshIsActive: model.libraryCoordinator?.isRefreshing ?? false,
            refresh: { model.libraryCoordinator?.refresh() },
            setup: { showsSetupAndSync = true }
        )
    }

    @ViewBuilder
    private var unifiedLibraryEmptyState: some View {
        if model.transferCoordinator == nil {
            ProgressView("Opening protected recordings…")
        } else {
            libraryRefreshStatus
        }
    }

    @ViewBuilder
    private func unifiedLibraryRow(
        _ item: HarcMobileUnifiedLibraryItem
    ) -> some View {
        switch item {
        case .local(let recording):
            if let transfer = model.transferCoordinator {
                HarcMobileLocalRecordingRow(
                    recording: recording,
                    captureIsActive:
                        model.captureCoordinator?.isRecording ?? false,
                    retryTransfer: transfer.retry(recordingUUID:),
                    transferRetryIsAvailable:
                        transfer.isCodecQualifiedForTransfers
                )
            }
        case .host(let recording):
            if let coordinator = model.libraryCoordinator {
                NavigationLink {
                    HarcMobileRecordingDetailView(
                        coordinator: coordinator,
                        summary: recording
                    )
                } label: {
                    HarcMobileHostRecordingRow(
                        recording: recording,
                        summary: nil
                    )
                }
            }
        }
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

    @ViewBuilder
    private func librarySearchView(
        _ coordinator: HarcMobileLibraryCoordinator
    ) -> some View {
        let hostOrigins = Set(
            (coordinator.recordings + coordinator.searchResults.map(\.recording))
                .compactMap(\.originID)
        )
        let localMatches = HarcMobileUnifiedLibrary.localTitleMatches(
            model.transferCoordinator?.localRecordings ?? [],
            query: libraryQuery,
            excludingHostOrigins: hostOrigins
        )
        if coordinator.isSearching,
           coordinator.searchResults.isEmpty,
           localMatches.isEmpty {
            ProgressView("Searching Host…")
        } else if coordinator.searchResults.isEmpty, localMatches.isEmpty {
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
                        HarcMobileLibrarySearchRow(
                            result: result,
                            query: libraryQuery
                        )
                    }
                }
                ForEach(localMatches) { recording in
                    if let transfer = model.transferCoordinator {
                        HarcMobileLocalRecordingRow(
                            recording: recording,
                            captureIsActive:
                                model.captureCoordinator?.isRecording
                                    ?? false,
                            retryTransfer:
                                transfer.retry(recordingUUID:),
                            transferRetryIsAvailable:
                                transfer.isCodecQualifiedForTransfers,
                            highlightQuery: libraryQuery
                        )
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
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        recordHeader(captureState: coordinator.state)
                        recordingConditions
                            .padding(.top, 14)

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
                            todayRecordingsCard(transfer)
                                .padding(.bottom, 12)

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
            .background { HarcTideBackground() }
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
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Text("Record")
                    .font(.system(.title, design: .rounded, weight: .bold))
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HarcMobileHostPill(
                    presentation: .make(
                        status: model.hostHealthCoordinator?.status
                            ?? .unpaired,
                        hostName: adoptedHostName
                    )
                ) {
                    showsSetupAndSync = true
                }
            }
        }
    }

    private func todayRecordingsCard(_ transfer: HarcMobileTransferCoordinator) -> some View {
        let today = transfer.localRecordings.filter {
            Calendar.current.isDateInToday($0.startedAt)
        }
        let duration = today.reduce(0) { $0 + $1.duration }
        return Button { showsLocalRecordings = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                layout {
                    Text("Today")
                        .font(.system(.headline, design: .rounded))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text(today.isEmpty ? "No recordings yet" : "\(today.count) recordings · \(Int(duration / 60)) min")
                        .font(.system(size: daySummaryTextSize))
                        .foregroundStyle(.primary)
                }
                if !today.isEmpty {
                    HarcTideDayTimeline(intervals: today.map {
                        DateInterval(start: $0.startedAt, duration: max(0, $0.duration))
                    })
                    .frame(height: 48)
                    let axisLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout())
                    axisLayout {
                        Text("12 AM")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text("On this iPhone")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text("Midnight")
                    }
                    .font(.system(size: dayAxisTextSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                }
                Label("View recordings on this iPhone", systemImage: "chevron.right")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("harc.mobile.record.today")
        .accessibilityHint("Opens recordings on this iPhone")
    }

    private var recordingConditions: some View {
        HarcTideConditions {
            Label("iPhone mic", systemImage: "mic")
                .fontWeight(.bold)
            if let transfer = model.transferCoordinator {
                let pending = HarcMobileCaptureStatusPresentation.effectivePendingCount(
                    pendingCount: transfer.pendingCount,
                    localRecordings: transfer.localRecordings
                )
                Text("\(pending) to send")
            }
            if let capture = model.captureCoordinator, capture.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = Int(capture.durableAudioSeconds)
                    Label(seconds > 0
                          ? "\(seconds / 60):\(String(format: "%02d", seconds % 60)) saved"
                          : "Preparing first save", systemImage: "lock.shield")
                }
            } else {
                Label("On this iPhone", systemImage: "lock.shield")
            }
        }
        .accessibilityElement(children: .combine)
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

private extension View {
    @ViewBuilder
    func harcMobileCaptureAccessory<Accessory: View>(
        isEnabled: Bool,
        @ViewBuilder content: () -> Accessory
    ) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled, content: content)
        } else {
            // Keep the tab hierarchy stable on 26.0 while capture changes.
            // Explicit accessory visibility was added in 26.1.
            tabViewBottomAccessory(content: content)
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
    let highlightQuery: String?

    @State private var audio: HarcMobileLocalRecordingAudioController
    @State private var showsExport = false

    init(
        recording: HarcMobileLocalRecording,
        captureIsActive: Bool,
        retryTransfer: @escaping (UUID) -> Void,
        transferRetryIsAvailable: Bool,
        highlightQuery: String? = nil
    ) {
        self.recording = recording
        self.captureIsActive = captureIsActive
        self.retryTransfer = retryTransfer
        self.transferRetryIsAvailable = transferRetryIsAvailable
        self.highlightQuery = highlightQuery
        _audio = State(
            initialValue: HarcMobileLocalRecordingAudioController(
                url: recording.masterFileURL
            )
        )
    }

    var body: some View {
        NavigationLink {
            HarcMobileLocalRecordingDetailView(
                recording: recording,
                captureIsActive: captureIsActive,
                retryTransfer: retryTransfer,
                transferRetryIsAvailable: transferRetryIsAvailable
            )
        } label: {
            HarcMobileLocalRecordingLabel(
                recording: recording,
                highlightQuery: highlightQuery
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Export", systemImage: "square.and.arrow.up") {
                audio.stop()
                showsExport = true
            }
            .tint(.blue)
            .disabled(captureIsActive)

            Button(playbackActionTitle, systemImage: playbackActionSymbol) {
                Task { await audio.playOrPause() }
            }
            .tint(HarcMobilePalette.action)
            .disabled(captureIsActive)
        }
        .sheet(isPresented: $showsExport) {
            HarcMobileLocalRecordingExportView(
                recording: recording,
                isPresented: $showsExport
            )
        }
        .accessibilityIdentifier("harc.mobile.local.recording.\(recording.id)")
        .onDisappear { audio.stop() }
    }

    private var playbackActionTitle: String {
        if case .playing = audio.state { return "Pause" }
        return "Play"
    }

    private var playbackActionSymbol: String {
        if case .playing = audio.state { return "pause.fill" }
        return "play.fill"
    }
}

private struct HarcMobileLocalRecordingLabel: View {
    let recording: HarcMobileLocalRecording
    let highlightQuery: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text("iPhone")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            Text(
                recording.startedAt.formatted(date: .omitted, time: .shortened)
                    + " · " + HarcMobileRecordingFormatting.duration(
                        recording.duration
                    )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("Transcript arrives after it reaches your Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    private var title: AttributedString {
        let rawTitle = HarcMobileUnifiedLibrary.localTitle(recording)
        guard let highlightQuery, !highlightQuery.isEmpty else {
            return AttributedString(rawTitle)
        }
        return HarcMobileRecordingFormatting.highlighted(
            rawTitle,
            query: highlightQuery
        )
    }
}

private struct HarcMobileLocalRecordingDetailView: View {
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
        List {
            Section {
                LabeledContent(
                    "Recorded",
                    value: recording.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                LabeledContent(
                    "Duration",
                    value: HarcMobileRecordingFormatting.duration(
                        recording.duration
                    )
                )
                transferStatus
            }

            Section("Audio") {
                Button {
                    Task { await audio.playOrPause() }
                } label: {
                    switch audio.state {
                    case .loading:
                        HStack { ProgressView(); Text("Loading audio…") }
                    case .playing:
                        Label("Pause", systemImage: "pause.fill")
                    default:
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .disabled(captureIsActive)
                .accessibilityIdentifier(
                    "harc.mobile.local.play.\(recording.id)"
                )

                Button("Export…", systemImage: "square.and.arrow.up") {
                    audio.stop()
                    showsExport = true
                }
                .disabled(captureIsActive)

                if captureIsActive {
                    Text("Playback and export are paused while recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = audio.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let discontinuity = recording.discontinuities.last {
                Section("Capture note") {
                    Label(
                        HarcMobileRecordingFormatting.discontinuityText(
                            discontinuity.reason
                        ),
                        systemImage: "waveform.badge.exclamationmark"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(HarcMobileUnifiedLibrary.localTitle(recording))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showsExport) {
            HarcMobileLocalRecordingExportView(
                recording: recording,
                isPresented: $showsExport
            )
        }
        .onDisappear { audio.stop() }
    }

    @ViewBuilder
    private var transferStatus: some View {
        switch recording.transferState {
        case .localOnly:
            LabeledContent("Sending", value: "Waiting")
        case .transferring:
            LabeledContent("Sending", value: "In progress")
        case .retryNeeded where !transferRetryIsAvailable:
            LabeledContent("Sending", value: "Waiting")
        case .securityBlocked where !transferRetryIsAvailable:
            LabeledContent("Sending", value: "Mac access needs review")
        case .retryNeeded:
            Button("Retry", systemImage: "arrow.clockwise") {
                retryTransfer(recording.id)
            }
            .foregroundStyle(.orange)
        case .securityBlocked:
            Button("Review & Retry", systemImage: "lock.open") {
                retryTransfer(recording.id)
            }
            .foregroundStyle(.red)
        case .committed:
            LabeledContent("Sending", value: "On Mac")
        }
    }
}

private struct HarcMobileLocalRecordingExportView: View {
    let recording: HarcMobileLocalRecording
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label(
                    "Export outside Harc",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.title2.weight(.semibold))
                Text(HarcMobileLocalRecording.exportDisclosure)
                    .accessibilityIdentifier(
                        HarcMobileAccessibilityID.exportDisclosure
                    )
                ShareLink(item: recording.masterFileURL) {
                    Label(
                        "Choose Export Destination",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(HarcMobileAccessibilityID.exportShare)
                Spacer()
            }
            .padding()
            .navigationTitle("Export Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct HarcMobileHostRecordingRow: View {
    let recording: LibraryRecordingSummary
    let summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.title ?? recording.suggestedTitle ?? "Untitled Recording")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if recording.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(hostMetadata)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isProcessing {
                Text("Transcribing on your Mac…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var hostMetadata: String {
        var components = [
            recording.startedAt.formatted(date: .omitted, time: .shortened)
        ]
        if let endedAt = recording.endedAt {
            components.append(
                HarcMobileRecordingFormatting.duration(
                    endedAt.timeIntervalSince(recording.startedAt)
                )
            )
        }
        return components.joined(separator: " · ")
    }

    private var isProcessing: Bool {
        switch recording.processing.state {
        case .pending, .transcribing, .projecting: true
        case .ready, .degraded, .failedRecoverable: false
        }
    }
}

private struct HarcMobileLibrarySearchRow: View {
    let result: HarcMobileLibraryCoordinator.SearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HarcMobileHostRecordingRow(
                recording: result.recording,
                summary: nil
            )
            if let matchContext {
                Text(matchContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let snippet = result.snippets.first, !snippet.isEmpty {
                Text(HarcMobileRecordingFormatting.highlighted(
                    snippet,
                    query: query
                ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var matchContext: String? {
        guard let timestamp = result.matchTimestamp else { return nil }
        let speaker = result.matchSpeakerIndex.map { "Speaker \($0)" }
            ?? "Transcript"
        return "\(speaker) at \(HarcMobileRecordingFormatting.duration(timestamp))"
    }
}

private enum HarcMobileRecordingFormatting {
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func highlighted(_ markedText: String, query: String) -> AttributedString {
        let clean = markedText
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
        var value = AttributedString(clean)
        if let range = value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            value[range].backgroundColor = .yellow.opacity(0.45)
            value[range].foregroundColor = .primary
        }
        return value
    }

    static func discontinuityText(
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

private struct HarcMobileRecordingDetailView: View {
    let coordinator: HarcMobileLibraryCoordinator
    let summary: LibraryRecordingSummary

    private enum DetailSection: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"
    }
    @State private var selectedSection: DetailSection = .summary
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
    @State private var showsCopyConfirmation = false
    @State private var didCopyPrompt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
                    Section {
                        TextField("Recording title", text: $titleDraft)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .onSubmit {
                                let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                submitMetadata(.setTitle(title.isEmpty ? nil : title))
                            }
                        Text(summary.startedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HarcTideConditions {
                            Label("\(detail.speakerLabels.count) speakers", systemImage: "person.2")
                            Text(detail.summary.canonicalAudio.availability == .available
                                 ? "Verified on Mac" : "Audio pending")
                        }
                    }
                    if detail.summary.canonicalAudio.availability == .available {
                        Section("Audio") {
                            audioPlaybackControls
                            if case .failed(let message) = audioController.state {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    Picker("Sections", selection: $selectedSection) {
                        ForEach(DetailSection.allCases, id: \.self) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    Section {
                        DisclosureGroup("Recording status") {
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
                    if selectedSection == .transcript {
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
                    }
                    if selectedSection == .notes {
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
                    if selectedSection == .transcript, let transcript = detail.transcriptText,
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
                    if selectedSection == .summary, detail.summaryMarkdown?.isEmpty != false {
                        Text("A summary will appear here when it is available from your Mac.")
                            .foregroundStyle(.secondary)
                    }
                    if selectedSection == .transcript, detail.transcriptText?.isEmpty != false {
                        Text("A transcript will appear here when it is available from your Mac.")
                            .foregroundStyle(.secondary)
                    }
                    if selectedSection == .summary, let generatedSummary = detail.summaryMarkdown,
                       !generatedSummary.isEmpty {
                        Section("Summary") {
                            Text(generatedSummary)
                                .textSelection(.enabled)
                        }
                    }
                    if selectedSection == .summary, let actionItems = detail.actionItemsMarkdown,
                       !actionItems.isEmpty {
                        Section("Action Items") {
                            Text(actionItems)
                                .textSelection(.enabled)
                        }
                    }
                    if selectedSection == .notes, let notes = detail.notesMarkdown, !notes.isEmpty {
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
        .scrollContentBackground(.hidden)
        .background { HarcTideBackground() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(didCopyPrompt ? "Copied" : "Copy for Prompt") {
                    showsCopyConfirmation = true
                }
                .disabled(detail == nil)
            }
        }
        .confirmationDialog("Copy recording text?", isPresented: $showsCopyConfirmation, titleVisibility: .visible) {
            Button("Copy to this iPhone") { copyForPrompt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The title, summary, actions, notes, and transcript will be copied to this iPhone’s clipboard for five minutes. Pasting into another app shares that text outside your paired Mac and iPhone.")
        }
        .task(id: summary.canonicalID) {
            await loadDetail()
        }
        .onDisappear { audioController.stopAndRelease() }
    }

    private var audioPlaybackControls: some View {
        TimelineView(.animation(
            minimumInterval: reduceMotion ? 0.25 : 1.0 / 30,
            paused: scenePhase != .active
        )) { _ in
            VStack(spacing: 16) {
                Text(Duration.seconds(audioController.currentTime), format: .time(pattern: .minuteSecond))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .accessibilityLabel("Playback position")
                if !audioController.envelope.isEmpty {
                    HarcTideEnergyTrace(
                        samples: audioController.envelope,
                        playbackProgress: audioController.currentTime / max(1, audioController.duration)
                    )
                        .frame(height: 100)
                        .accessibilityLabel("Recorded audio energy")
                }
                Slider(value: Binding(
                    get: { audioController.currentTime },
                    set: { audioController.seek(to: $0) }
                ), in: 0...max(1, audioController.duration))
                .disabled(!audioController.canSeek)
                .accessibilityLabel("Playback position")
                HStack(spacing: 32) {
                    Button("Back 15 seconds", systemImage: "gobackward.15") {
                        audioController.seek(to: audioController.currentTime - 15)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!audioController.canSeek)
                    Button {
                        Task { await audioController.playOrPause() }
                    } label: {
                        audioPlaybackLabel
                    }
                    .disabled(audioController.state == .downloading)
                    Button("Forward 15 seconds", systemImage: "goforward.15") {
                        audioController.seek(to: audioController.currentTime + 15)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!audioController.canSeek)
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)
        }
    }

    private func copyForPrompt() {
        guard let detail else { return }
        var parts = ["# \(detail.summary.title ?? detail.summary.suggestedTitle ?? "Recording")"]
        for (heading, text) in [("Summary", detail.summaryMarkdown),
                                ("Action items", detail.actionItemsMarkdown),
                                ("Notes", detail.notesMarkdown)] {
            if let text, !text.isEmpty { parts.append("## \(heading)\n\(text)") }
        }
        if let transcript = detail.transcriptText, !transcript.isEmpty {
            parts.append("## Transcript\n" + SpeakerTranscriptLabelProjector.project(transcript, labels: detail.speakerLabels))
        }
        UIPasteboard.general.setItems([["public.utf8-plain-text": parts.joined(separator: "\n\n")]],
                                     options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(300)])
        didCopyPrompt = true
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
