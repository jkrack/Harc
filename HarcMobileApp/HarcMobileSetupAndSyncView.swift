import HarcDomain
import HarcPresenceUI
import SwiftUI
import UIKit

struct HarcMobileSetupAndSyncView: View {
    @Environment(HarcMobileAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showsPairing = false
    @State private var showsReviewSample = false
    @State private var showsForgetConfirmation = false
    @State private var localStorageBytes: Int64?

    var body: some View {
        NavigationStack {
            List {
                if !model.rejectedCaptureMetadataFiles.isEmpty {
                    Section { rejectedCaptureMetadataWarning }
                }

                Section { macCard }

                Section("Sync") {
                    NavigationLink {
                        HarcMobileSendingToMacView(setupDestination: .existingSetup)
                    } label: {
                        Label {
                            LabeledContent(
                                "Sending to Mac",
                                value: sendingSummary
                            )
                        } icon: {
                            Image(systemName: "arrow.up")
                        }
                    }
                    .accessibilityIdentifier(
                        HarcMobileSyncAccessibilityID.hostStatusLink
                    )

                    NavigationLink {
                        HarcMobileSendingToMacView(
                            initialSection: .macLibrary,
                            setupDestination: .existingSetup
                        )
                    } label: {
                        Label {
                            LabeledContent(
                                "Mac Library",
                                value: libraryUpdatedSummary
                            )
                        } icon: {
                            Image(systemName: "rectangle.stack")
                        }
                    }
                }

                Section("This iPhone") {
                    NavigationLink {
                        HarcMobileLocalRecordingsView()
                    } label: {
                        Label {
                            if let localStorageBytes {
                                LabeledContent(
                                    "Recordings & storage",
                                    value: ByteCountFormatter.string(
                                        fromByteCount: localStorageBytes,
                                        countStyle: .file
                                    )
                                )
                            } else {
                                Text("Recordings & storage")
                            }
                        } icon: {
                            Image(systemName: "iphone")
                        }
                    }

                    NavigationLink {
                        HarcMobilePrivacyView()
                    } label: {
                        Label(
                            "Privacy & data",
                            systemImage: "hand.raised"
                        )
                    }
                }

                Section {
                    NavigationLink {
                        HarcMobileAdvancedView(
                            showsReviewSample: $showsReviewSample,
                            showsForgetConfirmation:
                                $showsForgetConfirmation
                        )
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text(
                        "Audio stays on your iPhone and your Mac. No cloud account."
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background { HarcTideBackground() }
            .navigationTitle("Setup & Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier(HarcMobileAccessibilityID.setupAndSync)
        .sheet(isPresented: $showsPairing) {
            HarcMobilePairingFlowView()
        }
        .sheet(isPresented: $showsReviewSample) {
            NavigationStack { HarcMobileReviewSampleView() }
        }
        .confirmationDialog(
            "Forget \(adoptedMacName)?",
            isPresented: $showsForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget \(adoptedMacName)", role: .destructive) {
                model.pairingCoordinator?.forgetActiveHost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the saved pairing from this iPhone. Recordings stay here. Remove this iPhone on your Mac too if it should no longer be trusted."
            )
        }
        .task(id: localStorageTaskID) {
            localStorageBytes = nil
            let urls = model.transferCoordinator?.localRecordings.map(
                \.masterFileURL
            ) ?? []
            localStorageBytes = await Task.detached {
                urls.reduce(into: Int64.zero) { total, url in
                    let values = try? url.resourceValues(
                        forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
                    )
                    total += Int64(
                        values?.totalFileAllocatedSize
                            ?? values?.fileSize
                            ?? 0
                    )
                }
            }.value
        }
    }

    @ViewBuilder
    private var macCard: some View {
        let status = model.hostHealthCoordinator?.status ?? .unpaired
        HarcMobileMacCard(
            name: adoptedMacName,
            status: status,
            checkNow: {
                Task { await model.hostHealthCoordinator?.refresh() }
            },
            pairOrChange: {
                model.pairingCoordinator?.beginReplacement()
                showsPairing = true
            }
        )
    }

    private var adoptedMacName: String {
        model.hostHealthCoordinator?.hostDisplayName
            ?? model.pairingCoordinator?.pairedHostDisplayName
            ?? "Your Mac"
    }

    private var sendingSummary: String {
        let count = syncStatus.pendingCount
        return count == 0 ? "None waiting" : "\(count) waiting"
    }

    private var libraryUpdatedSummary: String {
        guard let date = model.libraryCoordinator?.lastUpdatedAt else {
            return "Not updated"
        }
        return date.formatted(.relative(presentation: .numeric))
    }

    private var syncStatus: HarcMobileSyncStatusPresentation {
        let transfer = model.transferCoordinator
        return .make(
            host: .init(model.hostHealthCoordinator?.status ?? .unpaired),
            transfer: transfer.map { .init($0.state) } ?? .preparing,
            codecQualified:
                transfer?.isCodecQualifiedForTransfers ?? false,
            pendingCount: transfer.map {
                HarcMobileCaptureStatusPresentation.effectivePendingCount(
                    pendingCount: $0.pendingCount,
                    localRecordings: $0.localRecordings
                )
            } ?? 0
        )
    }

    private var localStorageTaskID: [UUID] {
        model.transferCoordinator?.localRecordings.map(\.id) ?? []
    }

    private var rejectedCaptureMetadataWarning: some View {
        Label(
            "Some saved audio needs recovery. Harc kept the files on this iPhone. You can keep recording.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
    }
}

struct HarcMobileMacCard: View {
    let name: String
    let status: HarcMobileHostHealthStatus
    let checkNow: () -> Void
    let pairOrChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "macmini")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        statusLine
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            switch status {
            case .unpaired:
                Button("Pair a Mac", action: pairOrChange)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            case .pairingRepairRequired:
                Button("Repair", action: pairOrChange)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            case .checking:
                HStack {
                    ProgressView()
                    Text("Checking connection…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .connected, .unavailable:
                HStack {
                    Button("Check now", action: checkNow)
                        .buttonStyle(.borderedProminent)
                    Button("Change Mac", action: pairOrChange)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch status {
        case .unpaired:
            "Pair your Mac"
        case .pairingRepairRequired:
            "Pairing needs repair"
        default:
            name
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .unpaired:
            Text("Not paired")
        case .checking:
            Text("Checking")
        case .connected(let date):
            Text("Connected · checked ") + Text(date, style: .relative)
        case .unavailable(let date):
            Text("Unavailable · checked ") + Text(date, style: .relative)
        case .pairingRepairRequired:
            Text("Saved pairing needs attention")
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            .green
        case .checking:
            .blue
        case .unavailable, .pairingRepairRequired:
            .orange
        case .unpaired:
            .secondary
        }
    }
}

struct HarcMobileSendingToMacView: View {
    enum SectionTarget: Hashable {
        case status
        case macLibrary
    }

    enum SetupDestination {
        case existingSetup
        case sheet
    }

    @Environment(HarcMobileAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialSection: SectionTarget
    let setupDestination: SetupDestination
    @State private var showsLibrarySetup = false

    init(
        initialSection: SectionTarget = .status,
        setupDestination: SetupDestination
    ) {
        self.initialSection = initialSection
        self.setupDestination = setupDestination
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(chipTitle, systemImage: chipSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chipColor)
                        Text(presentationTitle)
                            .font(.title3.weight(.bold))
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        HarcMobileSyncAccessibilityID.transferStatus
                    )
                }
                .id(SectionTarget.status)

                Section {
                    if pendingRecordings.isEmpty {
                        Text("No recordings waiting")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pendingRecordings) { recording in
                            HarcMobileSendingQueueRow(recording: recording)
                        }
                    }

                    Button("Send now") {
                        model.transferCoordinator?.retryPending()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isTransferGated)
                    .accessibilityIdentifier(
                        HarcMobileSyncAccessibilityID.retryTransfers
                    )
                } header: {
                    Text("Queue")
                } footer: {
                    Text(
                        "Each recording stays on this iPhone until your Mac confirms it has a verified copy."
                    )
                }

                Section("Mac Library") {
                    HarcMobileLibraryRefreshStatusView(
                        state: model.libraryCoordinator?.state ?? .loadingCache,
                        hasRows: !(model.libraryCoordinator?.recordings.isEmpty ?? true),
                        refreshIsActive: model.libraryCoordinator?.isRefreshing ?? false,
                        refresh: { model.libraryCoordinator?.refresh() },
                        setup: openLibrarySetup
                    )
                    if let date = model.libraryCoordinator?.lastUpdatedAt {
                        LabeledContent("Last updated") {
                            Text(date, style: .relative)
                        }
                    } else {
                        LabeledContent("Last updated", value: "Not yet")
                    }
                }
                .id(SectionTarget.macLibrary)
            }
            .onAppear {
                guard initialSection == .macLibrary else { return }
                Task { @MainActor in
                    withAnimation { proxy.scrollTo(SectionTarget.macLibrary) }
                }
            }
        }
        .sheet(isPresented: $showsLibrarySetup) {
            HarcMobileSetupAndSyncView()
        }
        .navigationTitle("Sending to Mac")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(HarcMobileSyncAccessibilityID.detail)
    }

    private func openLibrarySetup() {
        switch setupDestination {
        case .existingSetup:
            dismiss()
        case .sheet:
            showsLibrarySetup = true
        }
    }

    private var presentation: HarcMobileSyncStatusPresentation {
        let transfer = model.transferCoordinator
        return .make(
            host: .init(model.hostHealthCoordinator?.status ?? .unpaired),
            transfer: transfer.map { .init($0.state) } ?? .preparing,
            codecQualified:
                transfer?.isCodecQualifiedForTransfers ?? false,
            pendingCount: transfer.map {
                HarcMobileCaptureStatusPresentation.effectivePendingCount(
                    pendingCount: $0.pendingCount,
                    localRecordings: $0.localRecordings
                )
            } ?? 0
        )
    }

    private var presentationTitle: String {
        let count = presentation.pendingCount
        if count == 0 { return "No recordings waiting to send" }
        return "\(count) recording\(count == 1 ? "" : "s") waiting"
    }

    private var explanation: String {
        return presentation.detail
            .replacingOccurrences(of: "Host", with: "Mac")
    }

    private var chipTitle: String {
        switch presentation.reason {
        case .working:
            "Sending"
        case .nothingPending, .receiptVerified:
            "Nothing waiting"
        case .securityBlocked, .retryNeeded:
            "Needs attention"
        default:
            "Paused"
        }
    }

    private var chipSymbol: String {
        switch presentation.reason {
        case .working:
            "arrow.up.circle.fill"
        case .nothingPending, .receiptVerified:
            "checkmark.circle.fill"
        case .securityBlocked, .retryNeeded:
            "exclamationmark.triangle.fill"
        default:
            "pause.circle.fill"
        }
    }

    private var chipColor: Color {
        switch presentation.reason {
        case .working:
            .blue
        case .nothingPending, .receiptVerified:
            .green
        case .securityBlocked, .retryNeeded:
            .orange
        default:
            .secondary
        }
    }

    private var pendingRecordings: [HarcMobileLocalRecording] {
        model.transferCoordinator?.localRecordings.filter {
            $0.transferState != .committed
        } ?? []
    }

    private var isTransferGated: Bool {
        presentation.action != .retryTransfers
            || (model.captureCoordinator?.isRecording ?? false)
    }
}

private struct HarcMobileSendingQueueRow: View {
    let recording: HarcMobileLocalRecording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "Recording "
                        + recording.startedAt.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                )
                Text(
                    recording.startedAt.formatted(
                        .dateTime.month(.abbreviated).day()
                    )
                        + " · "
                        + Self.duration(recording.duration)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateTitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var stateTitle: String {
        switch recording.transferState {
        case .localOnly:
            "Waiting"
        case .transferring:
            "Sending"
        case .retryNeeded:
            "Retry"
        case .securityBlocked:
            "Failed"
        case .committed:
            "Sent"
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct HarcMobileLocalRecordingsView: View {
    @Environment(HarcMobileAppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let transfer = model.transferCoordinator {
                    if let error = transfer.localRecordingsError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if transfer.localRecordings.isEmpty {
                        ContentUnavailableView(
                            "No recordings on this iPhone",
                            systemImage: "iphone"
                        )
                    }
                    ForEach(transfer.localRecordings) { recording in
                        HarcMobileLocalRecordingRow(
                            recording: recording,
                            captureIsActive:
                                model.captureCoordinator?.isRecording
                                    ?? false,
                            retryTransfer:
                                transfer.retry(recordingUUID:),
                            transferRetryIsAvailable:
                                transfer.isCodecQualifiedForTransfers
                        )
                    }
                } else {
                    ProgressView("Opening protected local recordings…")
                }
            }
            .padding()
        }
        .navigationTitle("On This iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(HarcMobileAccessibilityID.localRecordings)
    }
}

private struct HarcMobileAdvancedView: View {
    @Environment(HarcMobileAppModel.self) private var model
    @Binding var showsReviewSample: Bool
    @Binding var showsForgetConfirmation: Bool

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent(
                    "Transport",
                    value: "Pinned TLS, signed grant"
                )
                LabeledContent("Transfer format", value: transferFormat)
                LabeledContent("Device ID") {
                    Button {
                        UIPasteboard.general.string = deviceID?.description
                    } label: {
                        Text(truncatedDeviceID + "  Copy")
                            .font(.caption.monospaced())
                    }
                    .disabled(deviceID == nil)
                    .accessibilityLabel("Copy device ID")
                }
            }

            Section {
                Button("Clear downloaded audio") {
                    try? model.libraryCoordinator?.clearDownloadedAudio()
                }
                Button("Rebuild Library cache") {
                    try? model.libraryCoordinator?.resetLibraryCache()
                }
            } header: {
                Text("Mac Library cache")
            } footer: {
                Text(
                    "Recordings on this iPhone are never touched by these."
                )
            }

            Section("Recovery") {
                LabeledContent(
                    "Files needing recovery",
                    value: recoveryCount == 0
                        ? "None"
                        : "\(recoveryCount)"
                )
                Button("Open offline review sample") {
                    showsReviewSample = true
                }
                .accessibilityIdentifier(
                    HarcMobileAccessibilityID.openReviewSample
                )
            }

            if model.pairingCoordinator?.pairedHostDisplayName != nil {
                Section {
                    Button(
                        "Forget \(macName)",
                        role: .destructive
                    ) {
                        showsForgetConfirmation = true
                    }
                } footer: {
                    Text(
                        "Removes the pairing from this iPhone only. Recordings stay here. To fully revoke access, remove this iPhone on your Mac too."
                    )
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var transferFormat: String {
        let qualified =
            model.transferCoordinator?.isCodecQualifiedForTransfers ?? false
        return qualified ? "Lossless · qualified" : "Lossless · not qualified"
    }

    private var deviceID: DeviceID? {
        guard case .ready(let deviceID, _) = model.readiness else {
            return nil
        }
        return deviceID
    }

    private var truncatedDeviceID: String {
        guard let deviceID else { return "Unavailable" }
        return String(deviceID.description.prefix(16)) + "…"
    }

    private var recoveryCount: Int {
        model.rejectedCaptureMetadataFiles.count
    }

    private var macName: String {
        model.hostHealthCoordinator?.hostDisplayName
            ?? model.pairingCoordinator?.pairedHostDisplayName
            ?? "Mac"
    }
}

private struct HarcMobilePairingFlowView: View {
    @Environment(HarcMobileAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressStrip
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Group {
                    if isScanning {
                        scanStep
                    } else if let coordinator = model.pairingCoordinator {
                        pairingStep(coordinator)
                    } else {
                        ProgressView("Preparing secure pairing…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.pairingCoordinator?.pairingScannerCancelled()
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: model.pairingCoordinator?.state) { _, state in
            guard !isScanning, case .paired = state else { return }
            dismiss()
        }
    }

    private var currentStep: Int {
        if isScanning { return 1 }
        return switch model.pairingCoordinator?.state {
        case .compareWords:
            2
        case .awaitingHostApproval, .paired:
            3
        default:
            1
        }
    }

    private var progressStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            stepLabel(1, "Scan code")
            stepLabel(2, "Compare words")
            stepLabel(3, "Approve on Mac")
        }
    }

    private func stepLabel(_ step: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(
                    step <= currentStep
                        ? Color.accentColor
                        : Color.secondary.opacity(0.2)
                )
                .frame(height: 4)
            Text("\(step) \(label)")
                .font(.caption2)
                .fontWeight(step == currentStep ? .semibold : .regular)
                .foregroundStyle(
                    step <= currentStep ? .primary : .secondary
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scanStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Scan the code on your Mac")
                    .font(.title2.weight(.bold))
                Text(
                    "On your Mac, open Harc Settings and choose Pair a Device. A code appears there."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            HarcPairingScannerView(
                onCode: { code in
                    isScanning = false
                    Task {
                        await model.pairingCoordinator?.begin(
                            scannedURI: code
                        )
                    }
                },
                onFailure: { message in
                    isScanning = false
                    model.pairingCoordinator?.scannerFailed(message)
                }
            )
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityIdentifier(
                HarcMobileAccessibilityID.scanPairingCode
            )

            Text(
                "Harc asks for the camera to scan, then Local Network to reach your Mac directly. The code is short-lived and no cloud account is used."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(28)
    }

    @ViewBuilder
    private func pairingStep(
        _ coordinator: HarcMobilePairingCoordinator
    ) -> some View {
        switch coordinator.state {
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                Text("Securely connecting to your Mac…")
                    .foregroundStyle(.secondary)
            }
        case .compareWords(let host, let phrase, let expiresAt):
            compareWordsStep(
                coordinator,
                host: host,
                phrase: phrase,
                expiresAt: expiresAt
            )
        case .awaitingHostApproval(let host, _):
            VStack(spacing: 22) {
                ProgressView()
                    .controlSize(.large)
                Text("Approve this iPhone on \(host)")
                    .font(.title2.weight(.bold))
                Text(
                    "Harc on your Mac is asking whether to trust this iPhone. Choose Allow there to finish."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(28)
        case .failed(let message):
            ContentUnavailableView {
                Label(
                    "Pairing couldn't finish",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    coordinator.resetFailure()
                    isScanning = true
                }
                .buttonStyle(.borderedProminent)
            }
        case .unpaired, .paired:
            scanStep
        }
    }

    private func compareWordsStep(
        _ coordinator: HarcMobilePairingCoordinator,
        host: String,
        phrase: String,
        expiresAt: Date
    ) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Do these words match?")
                    .font(.title2.weight(.bold))
                Text(
                    "\(host) is showing four words. They should be exactly the same as these."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(Array(securityWords.enumerated()), id: \.offset) {
                    _, word in
                    Text(word)
                        .font(.title3.weight(.semibold).monospaced())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            .quaternary,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Security words: \(phrase)")

            Text("Code expires \(expiresAt, style: .relative)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("They match") {
                Task { await coordinator.confirmWordsMatch() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(
                HarcMobileAccessibilityID.pairingWordsMatch
            )

            Button("They don't match", role: .destructive) {
                Task { await coordinator.wordsDoNotMatch() }
            }
            .accessibilityIdentifier(
                HarcMobileAccessibilityID.pairingWordsMismatch
            )
        }
        .padding(28)
    }

    private var securityWords: [String] {
        guard case .compareWords(_, let phrase, _) =
            model.pairingCoordinator?.state else {
            return []
        }
        return phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
