import Combine
import CryptoKit
import Darwin
import Foundation
import HarcAudio
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
import HarcIdentity
import HarcStore
import HarcTransfer
import HarcUI
import Network

@MainActor
final class HarcDesktopClientRuntime: ObservableObject {
    @Published private(set) var pendingCaptureCount = 0
    @Published private(set) var statusMessage = "Client storage ready"
    @Published private(set) var lastRecoverSyncReport: ClientRecoverSyncReport?
    @Published private(set) var hostConnectionState: ClientHostConnectionState = .starting
    @Published private(set) var hostHealthSnapshot: ClientHostHealthSnapshot = .starting

    let identity: InstallationSigningIdentity
    let transferStore: HarcTransferStore
    let libraryCache: HarcLibraryCache
    let transferCoordinator: HarcDesktopClientTransferCoordinator
    let pairingCoordinator: HarcDesktopClientPairingCoordinator
    let libraryCoordinator: HarcMobileLibraryCoordinator
    let root: URL
    let routeURL: URL
    let diagnosticLog: HarcDiagnosticLogStore

    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(
        label: "com.harc.desktop-client.network-monitor",
        qos: .utility
    )
    private var networkWasSatisfied: Bool?
    private var hostHealthMonitoringTask: Task<Void, Never>?
    private static let hostHealthPollingInterval: Duration = .seconds(60)

    private init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        libraryCache: HarcLibraryCache,
        root: URL,
        audioPolicy: HarcLibraryAudioPolicy
    ) throws {
        self.identity = identity
        self.transferStore = transferStore
        self.libraryCache = libraryCache
        self.root = root
        diagnosticLog = try HarcDiagnosticLogStore(
            fileURL: root
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("client-diagnostics.jsonl")
        )
        diagnosticLog.append(
            severity: .info,
            area: "runtime",
            stage: "start",
            message: "Desktop Client runtime started",
            context: [
                "version": HarcVersion.current,
                "build": Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
            ]
        )
        let routeURL = root.appendingPathComponent("host-route.json")
        self.routeURL = routeURL
        let transferCoordinator = try HarcDesktopClientTransferCoordinator(
            identity: identity,
            store: transferStore,
            libraryCache: libraryCache,
            clientRoot: root,
            routeURL: routeURL,
            diagnosticLog: diagnosticLog
        )
        self.transferCoordinator = transferCoordinator
        let libraryCoordinator = HarcMobileLibraryCoordinator(
            identity: identity,
            transferStore: transferStore,
            cache: libraryCache,
            routeURL: routeURL,
            audioPolicy: audioPolicy
        )
        self.libraryCoordinator = libraryCoordinator
        pairingCoordinator = HarcDesktopClientPairingCoordinator(
            identity: identity,
            store: transferStore,
            routeURL: routeURL,
            hasActiveAdoption: try transferStore.activeAdoption() != nil
        ) {
            transferCoordinator.hostAdoptionDidChange()
            libraryCoordinator.refresh()
        } onForgetting: {
            transferCoordinator.forgetHostState()
            libraryCoordinator.shutdown()
        }
        transferCoordinator.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
            .store(in: &cancellables)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkPath(satisfied: satisfied)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
        refreshStatus()
    }

    static func start(
        audioPolicy: HarcLibraryAudioPolicy
    ) async throws -> HarcDesktopClientRuntime {
        let root = try clientRoot()
        let locations = try ClientStoreLocations(rootDirectory: root)
        let routeURL = root.appendingPathComponent("host-route.json")
        let hasPriorState = FileManager.default.fileExists(
            atPath: locations.transferDatabase.path
        ) || FileManager.default.fileExists(atPath: routeURL.path)
        let identityManager = InstallationIdentityManager(
            keyStore: KeychainSoftwareInstallationKeyStore(
                service: "com.harc.Harc.desktop-client.installation-identity",
                account: "device-p256-signing-v1",
                domain: .legacyMacOS
            )
        )
        let resolution = try await identityManager.resolve(
            evidence: InstallationIdentityEvidence(
                hasPriorIdentityState: hasPriorState,
                hasIdentityBoundCaptures: try hasDurableCaptures(root: root)
            )
        )
        guard case .available(let identity, _) = resolution else {
            throw HarcDesktopClientError.installationIdentityLost
        }
        let transferStore = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: identity.deviceID
        )
        let libraryCache = try HarcLibraryCache(rootDirectory: root)
        let startupRecovery = try HarcDesktopClientRecovery.reconcile(
            root: root,
            store: transferStore,
            deviceID: identity.deviceID
        )
        let runtime = try HarcDesktopClientRuntime(
            identity: identity,
            transferStore: transferStore,
            libraryCache: libraryCache,
            root: root,
            audioPolicy: audioPolicy
        )
        runtime.lastRecoverSyncReport = startupRecovery.report
        runtime.diagnosticLog.append(
            severity: startupRecovery.report.securityBlocked == 0
                ? .success : .warning,
            area: "recovery",
            stage: "startup-inventory",
            message: "Client archive inventory completed",
            context: Self.recoveryContext(startupRecovery.report)
        )
        runtime.transferCoordinator.setRecoveryBlockedOrigins(
            startupRecovery.blockedOrigins
        )
        try runtime.libraryCoordinator.applyAudioPolicy(audioPolicy)
        runtime.transferCoordinator.resumePending()
        runtime.libraryCoordinator.refresh()
        runtime.startHostHealthMonitoring()
        return runtime
    }

    func makeRecordingCommitter(
        localStore: RecordingStore,
        currentModelID: String
    ) throws -> any RecordingCommitter {
        try HarcDesktopClientRecordingCommitter(
            identity: identity,
            transferStore: transferStore,
            root: root,
            localStore: localStore,
            currentModelID: currentModelID
        ) { [weak self] localMirrorError in
            Task { @MainActor in
                if let localMirrorError {
                    self?.diagnosticLog.append(
                        severity: .warning,
                        area: "recovery",
                        stage: "tray-local-mirror-failed",
                        message: "The tray recording is protected but its immediate local Library mirror failed",
                        context: ["error": localMirrorError]
                    )
                } else {
                    self?.diagnosticLog.append(
                        severity: .success,
                        area: "recovery",
                        stage: "tray-local-mirror-complete",
                        message: "Tray recording added to the local Library"
                    )
                }
                self?.refreshStatus()
                self?.transferCoordinator.retryPending()
            }
        }
    }

    func refreshStatus() {
        do {
            pendingCaptureCount = try transferStore.recordingOutboxes().filter {
                $0.stateMachine.state != .committed
            }.count
            statusMessage = transferCoordinator.statusMessage
            hostConnectionState = try makeHostConnectionState()
            hostHealthSnapshot = try makeHostHealthSnapshot()
        } catch {
            statusMessage = error.localizedDescription
            hostConnectionState = .needsAttention(
                message: error.localizedDescription,
                lastContact: lastAuthenticatedHostContact,
                pending: pendingCaptureCount
            )
            hostHealthSnapshot = ClientHostHealthSnapshot(
                trust: .securityBlocked(error.localizedDescription),
                route: .unknown,
                session: .failed(error.localizedDescription),
                recordings: .blocked(
                    pendingCaptureCount,
                    error.localizedDescription
                ),
                processing: .blocked(
                    transferCoordinator.pendingProcessingCount,
                    error.localizedDescription
                ),
                speakers: .unknown,
                lastAuthenticatedAt: lastAuthenticatedHostContact
            )
        }
    }

    private func makeHostConnectionState() throws -> ClientHostConnectionState {
        let pending = transferCoordinator.pendingCount
        guard try transferStore.activeAdoption() != nil else {
            return .notPaired(pending: pending)
        }
        let lastContact = lastAuthenticatedHostContact
        if case .pairingRepairRequired(let message) = transferCoordinator
            .hostProbeState {
            return .securityBlocked(
                message: message,
                lastContact: lastContact,
                pending: pending
            )
        }
        if Self.transferIsIdle(transferCoordinator.state) {
            switch transferCoordinator.hostProbeState {
            case .checking:
                return .connecting(
                    lastContact: lastContact,
                    pending: pending
                )
            case .unavailable(let message):
                return .needsAttention(
                    message: message,
                    lastContact: lastContact,
                    pending: pending
                )
            case .notChecked, .reachable, .pairingRepairRequired:
                break
            }
        }
        switch transferCoordinator.state {
        case .waitingForPairing:
            // The durable adoption record is authoritative. The coordinator
            // can briefly retain its pre-adoption display state while retry
            // work is being scheduled, but that must not make Settings claim
            // the Host is no longer paired.
            return .paired(lastContact: lastContact, pending: pending)
        case .connecting:
            return .connecting(lastContact: lastContact, pending: pending)
        case .uploading:
            return .connected(
                lastContact: lastContact ?? Date(),
                pending: pending
            )
        case .retryNeeded(_, let message):
            return .needsAttention(
                message: message,
                lastContact: lastContact,
                pending: pending
            )
        case .securityBlocked(_, let message):
            return .securityBlocked(
                message: message,
                lastContact: lastContact,
                pending: pending
            )
        case .idle, .encoding, .uploaded, .edgeArtifactDeferred:
            return .paired(lastContact: lastContact, pending: pending)
        }
    }

    private func makeHostHealthSnapshot() throws -> ClientHostHealthSnapshot {
        let coordinator = transferCoordinator
        let pending = coordinator.pendingCount
        let processingPending = coordinator.pendingProcessingCount
        let speakerPending = coordinator.pendingSpeakerCount
        let speakerRepair = coordinator.speakerRepairCount
        let speakerReview = coordinator.speakerReviewCount
        let adoption = try transferStore.activeAdoption()
        let adopted = adoption != nil
        let contact = validatedContact(for: adoption)
        let lastContact = contact?.authenticatedAt

        let trust: ClientHostHealthSnapshot.Trust
        if !adopted {
            trust = .notPaired
        } else if case .securityBlocked(_, let message) = coordinator.state {
            trust = .securityBlocked(message)
        } else if case .pairingRepairRequired(let message) = coordinator
            .hostProbeState {
            trust = .securityBlocked(message)
        } else {
            trust = .adopted
        }

        let route: ClientHostHealthSnapshot.Route
        switch coordinator.state {
        case .connecting:
            route = .discovering
        case .retryNeeded(_, let message):
            route = .unavailable(message)
        default:
            switch coordinator.hostProbeState {
            case .checking:
                route = .discovering
            case .unavailable(let message),
                 .pairingRepairRequired(let message):
                route = .unavailable(message)
            case .notChecked, .reachable:
                switch contact?.route {
                case .direct: route = .direct
                case .encryptedRelay: route = .encryptedRelay
                case nil: route = .unknown
                }
            }
        }

        let session: ClientHostHealthSnapshot.Session
        switch coordinator.state {
        case .connecting:
            session = .authenticating
        case .uploading:
            session = .authenticated
        case .retryNeeded(_, let message),
             .securityBlocked(_, let message):
            session = .failed(message)
        default:
            switch coordinator.hostProbeState {
            case .checking:
                session = .authenticating
            case .unavailable(let message),
                 .pairingRepairRequired(let message):
                session = .failed(message)
            case .notChecked, .reachable:
                session = .idle
            }
        }

        let recordings = Self.workHealth(
            count: pending,
            state: coordinator.state
        )
        let processing = Self.workHealth(
            count: processingPending,
            state: coordinator.state
        )
        let speakers: ClientHostHealthSnapshot.SpeakerSync
        if speakerRepair > 0 || speakerReview > 0 {
            speakers = .needsAttention(
                repairing: speakerRepair,
                review: speakerReview
            )
        } else if speakerPending > 0 {
            speakers = .pending(speakerPending)
        } else {
            speakers = .current
        }
        return ClientHostHealthSnapshot(
            trust: trust,
            route: route,
            session: session,
            recordings: recordings,
            processing: processing,
            speakers: speakers,
            lastAuthenticatedAt: lastContact,
            nextAutomaticRetryAt: coordinator.nextAutomaticRetryAt
        )
    }

    private static func workHealth(
        count: Int,
        state: HarcDesktopClientTransferCoordinator.State
    ) -> ClientHostHealthSnapshot.Work {
        guard count > 0 else { return .current }
        switch state {
        case .encoding, .connecting, .uploading:
            return .syncing(count)
        case .retryNeeded(_, let message),
             .edgeArtifactDeferred(_, let message):
            return .retrying(count, message)
        case .securityBlocked(_, let message):
            return .blocked(count, message)
        default:
            return .pending(count)
        }
    }

    private static func transferIsIdle(
        _ state: HarcDesktopClientTransferCoordinator.State
    ) -> Bool {
        switch state {
        case .idle, .uploaded:
            true
        case .encoding, .waitingForPairing, .connecting, .uploading,
             .edgeArtifactDeferred, .retryNeeded, .securityBlocked:
            false
        }
    }

    private var lastAuthenticatedHostContact: Date? {
        let adoption = try? transferStore.activeAdoption()
        return validatedContact(for: adoption)?.authenticatedAt
    }

    private func validatedContact(
        for adoption: ActiveAdoptionSnapshot?
    ) -> HarcDesktopHostContactEvidence? {
        guard let adoption,
              let evidence = transferCoordinator.lastAuthenticatedContact,
              evidence.libraryID == adoption.tuple.libraryID.description,
              evidence.hostAuthorityID
                == adoption.tuple.hostAuthorityID.description else {
            return nil
        }
        return evidence
    }

    /// User-visible, repeat-safe repair pass over the private Client archive.
    /// Archive inventory runs off the main actor. Local reconciliation awaits
    /// database and transcription work while retry scheduling returns
    /// immediately and the coordinator reports live transfer progress.
    func recoverAndSync(
        localStore: RecordingStore,
        currentModelID: String,
        onLocalLibraryChange: @MainActor @escaping () async -> Void = {},
        transcribe: @MainActor @escaping (HarcDesktopClientRecovery.LocalCandidate) async throws
            -> HarcDesktopClientLocalTranscription
    ) async throws -> ClientRecoverSyncReport {
        diagnosticLog.append(
            severity: .info,
            area: "recovery",
            stage: "manual-start",
            message: "Recover & Sync requested"
        )
        let root = root
        let transferStore = transferStore
        let deviceID = identity.deviceID
        let outcome: HarcDesktopClientRecovery.Outcome
        do {
            outcome = try await Task.detached(priority: .userInitiated) {
                try HarcDesktopClientRecovery.reconcile(
                    root: root,
                    store: transferStore,
                    deviceID: deviceID
                )
            }.value
        } catch {
            diagnosticLog.append(
                severity: .error,
                area: "recovery",
                stage: "inventory-failed",
                message: "Client archive inventory failed",
                context: [
                    "error_type": String(reflecting: Swift.type(of: error)),
                ]
            )
            throw error
        }
        let localOutcome = await HarcDesktopClientLocalRecovery.reconcile(
            outcome.localCandidates,
            store: localStore,
            currentModelID: currentModelID,
            onLibraryChange: onLocalLibraryChange,
            transcribe: transcribe
        )
        let report = outcome.report.includingLocalRecovery(
            added: localOutcome.added,
            alreadyVisible: localOutcome.alreadyVisible,
            transcribed: localOutcome.transcribed,
            transcriptReused: localOutcome.transcriptReused,
            failed: localOutcome.failed,
            issues: localOutcome.issues
        )
        lastRecoverSyncReport = report
        diagnosticLog.append(
            severity: report.securityBlocked == 0
                    && report.localRecoveryFailed == 0
                    && report.issues.isEmpty
                ? .success : .warning,
            area: "recovery",
            stage: "inventory-complete",
            message: "Recover & Sync inventory completed",
            context: Self.recoveryContext(report)
        )
        transferCoordinator.setRecoveryBlockedOrigins(outcome.blockedOrigins)
        transferCoordinator.retryPending()
        refreshStatus()
        return report
    }

    func applyAudioPolicy(_ policy: HarcLibraryAudioPolicy) {
        do {
            try libraryCoordinator.applyAudioPolicy(policy)
        } catch {
            statusMessage =
                "Client audio policy could not clear retained Host audio: "
                + error.localizedDescription
        }
    }

    /// Wake and network restoration are route hints, never trust events. The
    /// subsequent connection still has to authenticate against the persisted
    /// Host authority before any queue work can advance.
    func handleConnectivityRestored() {
        transferCoordinator.retryPending()
        libraryCoordinator.refresh()
        transferCoordinator.probeHostIfIdle()
        refreshStatus()
    }

    private func startHostHealthMonitoring() {
        guard hostHealthMonitoringTask == nil else { return }
        hostHealthMonitoringTask = Task { [weak self] in
            self?.transferCoordinator.probeHostIfIdle()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: Self.hostHealthPollingInterval
                    )
                } catch {
                    return
                }
                self?.transferCoordinator.probeHostIfIdle()
            }
        }
    }

    private func handleNetworkPath(satisfied: Bool) {
        let wasSatisfied = networkWasSatisfied
        networkWasSatisfied = satisfied
        guard satisfied, wasSatisfied == false else { return }
        diagnosticLog.append(
            severity: .info,
            area: "connection",
            stage: "network-restored",
            message: "Network connectivity returned; pending Host work will retry"
        )
        handleConnectivityRestored()
    }

    func shutdown() {
        networkMonitor.cancel()
        hostHealthMonitoringTask?.cancel()
        hostHealthMonitoringTask = nil
        pairingCoordinator.cancel()
        transferCoordinator.shutdown()
        libraryCoordinator.shutdown()
    }

    private static func clientRoot() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw CocoaError(.fileNoSuchFile) }
        let root = support.appendingPathComponent(
            "Harc/ClientState",
            isDirectory: true
        )
        try HarcDesktopClientFiles.requireDirectory(root)
        return root
    }

    private static func hasDurableCaptures(root: URL) throws -> Bool {
        let directory = root.appendingPathComponent(
            "Captures",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "json" || $0.pathExtension == "wav" }
    }

    private static func recoveryContext(
        _ report: ClientRecoverSyncReport
    ) -> [String: String] {
        [
            "masters": String(report.mastersFound),
            "sidecars": String(report.sidecarsFound),
            "sidecars_rebuilt": String(report.sidecarsRebuilt),
            "outboxes_repaired": String(report.outboxesRepaired),
            "local_library_added": String(report.localLibraryAdded),
            "local_library_existing": String(report.alreadyInLocalLibrary),
            "locally_transcribed": String(report.transcribedLocally),
            "local_transcription_failed": String(report.localRecoveryFailed),
            "retry_requested": String(report.retryRequested),
            "already_on_host": String(report.alreadyOnHost),
            "security_blocked": String(report.securityBlocked),
            "issues": String(report.issues.count),
        ]
    }

}

enum HarcDesktopSpeakerProcessingStatus: String, Codable, Sendable {
    /// No local speaker-processing failure is known. There may legitimately be
    /// no observations when diarization is disabled or no speech is present.
    case ready
    /// Transcript audio is safe, but the local diarization pass failed and the
    /// Client recovery loop must retry it from the protected master.
    case retryNeeded = "retry-needed"
}

struct HarcDesktopClientCaptureSidecar: Codable, Sendable {
    let capture: FinalizedCapture
    let transcript: SessionTranscript?
    /// Optional for backward compatibility with captures created before
    /// federated speaker identity synchronization.
    let speakerEmbeddings: [SpeakerEmbeddingRow]?
    /// Optional for backward compatibility. A missing value does not claim a
    /// failure; only an explicitly persisted retry-needed state raises a local
    /// speaker-sync concern.
    let speakerProcessingStatus: HarcDesktopSpeakerProcessingStatus?
    let persistedAt: Date
    /// Stable link back to the pre-Client On This Mac row that produced this
    /// outbox item. Nil for recordings captured directly in Client mode.
    let sourceLocalCanonicalID: CanonicalRecordingID?

    init(
        capture: FinalizedCapture,
        transcript: SessionTranscript?,
        speakerEmbeddings: [SpeakerEmbeddingRow]?,
        speakerProcessingStatus: HarcDesktopSpeakerProcessingStatus? = nil,
        persistedAt: Date,
        sourceLocalCanonicalID: CanonicalRecordingID? = nil
    ) {
        self.capture = capture
        self.transcript = transcript
        self.speakerEmbeddings = speakerEmbeddings
        self.speakerProcessingStatus = speakerProcessingStatus
        self.persistedAt = persistedAt
        self.sourceLocalCanonicalID = sourceLocalCanonicalID
    }

    var speakerProcessingNeedsRetry: Bool {
        speakerProcessingStatus == .retryNeeded
    }
}

private struct HarcDesktopClientRecordingCommitter: RecordingCommitter {
    let identity: InstallationSigningIdentity
    let transferStore: HarcTransferStore
    let root: URL
    let localStore: RecordingStore
    let currentModelID: String
    let onAccepted: @Sendable (String?) -> Void

    init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        root: URL,
        localStore: RecordingStore,
        currentModelID: String,
        onAccepted: @escaping @Sendable (String?) -> Void
    ) throws {
        self.identity = identity
        self.transferStore = transferStore
        self.root = root
        self.localStore = localStore
        self.currentModelID = currentModelID
        self.onAccepted = onAccepted
    }

    func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
        let origin = identity.originRecordingID()
        let directory = root.appendingPathComponent(
            "Captures",
            isDirectory: true
        )
        try HarcDesktopClientFiles.requireDirectory(directory)
        let finalURL = directory.appendingPathComponent(
            "\(origin.recordingUUID.uuidString.lowercased()).wav"
        )
        let prepared = try HarcDesktopClientFiles.canonicalizeWAV(
            source: captured.localMasterURL,
            destination: finalURL
        )
        let durationNanoseconds = UInt64(
            max(0, captured.endedAt.timeIntervalSince(captured.startedAt))
                * 1_000_000_000
        )
        let capture = try FinalizedCapture(
            producingDeviceID: identity.deviceID,
            originRecordingID: origin,
            captureStartedAt: captured.startedAt,
            captureEndedAt: captured.endedAt,
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: durationNanoseconds,
            finalizationReason: .userStopped,
            totalCanonicalFrames: prepared.frames,
            totalCanonicalBytes: prepared.frames * 2,
            canonicalPCMSHA256: try CanonicalPCMHash(prepared.pcmSHA256),
            discontinuities: []
        )
        var transcript = captured.transcript
        transcript?.audioPath = finalURL.path
        let sidecar = HarcDesktopClientCaptureSidecar(
            capture: capture,
            transcript: transcript,
            speakerEmbeddings: captured.speakerEmbeddings,
            speakerProcessingStatus: captured.warnings.contains { warning in
                if case .diarizationFailed = warning { return true }
                return false
            } ? .retryNeeded : .ready,
            persistedAt: Date()
        )
        let sidecarURL = directory.appendingPathComponent(
            "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
        )
        try HarcDesktopClientFiles.writeSidecar(sidecar, to: sidecarURL)
        _ = try transferStore.persistFinalizedCapture(
            capture,
            masterFileURL: finalURL,
            persistedAt: sidecar.persistedAt
        )
        let localMirrorError: String?
        do {
            _ = try await HarcDesktopClientLocalRecovery.reconcilePersistedCapture(
                HarcDesktopClientRecovery.LocalCandidate(
                    masterURL: finalURL,
                    sidecarURL: sidecarURL,
                    sidecar: sidecar
                ),
                store: localStore,
                currentModelID: currentModelID
            )
            localMirrorError = nil
        } catch {
            // ClientState already owns a durable master and outbox. A local
            // Library mirror failure must not turn successful capture into a
            // false recording failure; the coalesced archive pass retries it.
            localMirrorError = error.localizedDescription
        }
        // The canonical ClientState master and sidecar are durable and the
        // outbox transaction owns recovery before the ephemeral capture cache
        // is consumed.
        try? FileManager.default.removeItem(at: captured.localMasterURL)
        onAccepted(localMirrorError)
        return .acceptedForDeferredPublication(localMasterURL: finalURL)
    }
}

enum HarcDesktopClientFiles {
    struct PreparedWAV {
        let frames: UInt64
        let pcmSHA256: Data
    }

    static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw HarcDesktopClientError.unsafePath }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    static func canonicalizeWAV(
        source: URL,
        destination: URL
    ) throws -> PreparedWAV {
        guard source.isFileURL, destination.isFileURL else {
            throw HarcDesktopClientError.unsafePath
        }
        try validateOwnedDirectory(destination.deletingLastPathComponent())
        let input = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw HarcDesktopClientError.invalidWAV }
        defer { Darwin.close(input) }
        var statBuffer = stat()
        guard fstat(input, &statBuffer) == 0,
              statBuffer.st_mode & S_IFMT == S_IFREG,
              statBuffer.st_size >= 44 else {
            throw HarcDesktopClientError.invalidWAV
        }
        let headerCount = min(Int(statBuffer.st_size), 64 * 1_024)
        var header = Data(count: headerCount)
        let headerRead = header.withUnsafeMutableBytes {
            pread(input, $0.baseAddress, headerCount, 0)
        }
        guard headerRead == headerCount,
              header.prefix(4) == Data("RIFF".utf8),
              header[8..<12] == Data("WAVE".utf8) else {
            throw HarcDesktopClientError.invalidWAV
        }
        let layout = try wavLayout(header)
        guard layout.dataBytes > 0, layout.dataBytes % 2 == 0,
              UInt64(layout.dataOffset) + UInt64(layout.dataBytes)
                <= UInt64(statBuffer.st_size),
              layout.dataBytes <= Int(UInt32.max) else {
            throw HarcDesktopClientError.invalidWAV
        }

        let output = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard output >= 0 else { throw HarcDesktopClientError.destinationExists }
        var succeeded = false
        defer {
            Darwin.close(output)
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        try writeAll(canonicalHeader(dataBytes: UInt32(layout.dataBytes)), to: output)
        var hasher = SHA256()
        var offset = 0
        while offset < layout.dataBytes {
            let count = min(1 * 1_024 * 1_024, layout.dataBytes - offset)
            var bytes = Data(count: count)
            let readCount = bytes.withUnsafeMutableBytes {
                pread(
                    input,
                    $0.baseAddress,
                    count,
                    off_t(layout.dataOffset + offset)
                )
            }
            guard readCount == count else { throw HarcDesktopClientError.invalidWAV }
            hasher.update(data: bytes)
            try writeAll(bytes, to: output)
            offset += count
        }
        guard fsync(output) == 0 else { throw HarcDesktopClientError.storageFailure }
        succeeded = true
        return PreparedWAV(
            frames: UInt64(layout.dataBytes / 2),
            pcmSHA256: Data(hasher.finalize())
        )
    }

    /// Validate and hash an existing canonical WAV without publishing a copy.
    /// Used only to recover a Reprocess staging file left between the durable
    /// master write and its sidecar/outbox transaction.
    static func inspectCanonicalWAV(_ source: URL) throws -> PreparedWAV {
        guard source.isFileURL else { throw HarcDesktopClientError.unsafePath }
        let input = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw HarcDesktopClientError.invalidWAV }
        defer { Darwin.close(input) }
        var statBuffer = stat()
        guard fstat(input, &statBuffer) == 0,
              statBuffer.st_mode & S_IFMT == S_IFREG,
              statBuffer.st_size >= 44 else {
            throw HarcDesktopClientError.invalidWAV
        }
        let headerCount = min(Int(statBuffer.st_size), 64 * 1_024)
        var header = Data(count: headerCount)
        let headerRead = header.withUnsafeMutableBytes {
            pread(input, $0.baseAddress, headerCount, 0)
        }
        guard headerRead == headerCount,
              header.prefix(4) == Data("RIFF".utf8),
              header[8..<12] == Data("WAVE".utf8) else {
            throw HarcDesktopClientError.invalidWAV
        }
        let layout = try wavLayout(header)
        guard layout.dataBytes > 0, layout.dataBytes % 2 == 0,
              UInt64(layout.dataOffset) + UInt64(layout.dataBytes)
                <= UInt64(statBuffer.st_size) else {
            throw HarcDesktopClientError.invalidWAV
        }
        var hasher = SHA256()
        var offset = 0
        while offset < layout.dataBytes {
            let count = min(1 * 1_024 * 1_024, layout.dataBytes - offset)
            var bytes = Data(count: count)
            let readCount = bytes.withUnsafeMutableBytes {
                pread(
                    input,
                    $0.baseAddress,
                    count,
                    off_t(layout.dataOffset + offset)
                )
            }
            guard readCount == count else { throw HarcDesktopClientError.invalidWAV }
            hasher.update(data: bytes)
            offset += count
        }
        return PreparedWAV(
            frames: UInt64(layout.dataBytes / 2),
            pcmSHA256: Data(hasher.finalize())
        )
    }

    static func writeSidecar(
        _ sidecar: HarcDesktopClientCaptureSidecar,
        to destination: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeProtectedData(encoder.encode(sidecar), to: destination)
    }

    static func replaceSidecar(
        _ sidecar: HarcDesktopClientCaptureSidecar,
        at destination: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeProtectedData(
            encoder.encode(sidecar),
            to: destination,
            replacingExistingRegularFile: true
        )
    }

    static func writeProtectedData(
        _ data: Data,
        to destination: URL,
        replacingExistingRegularFile: Bool = false
    ) throws {
        try validateOwnedDirectory(destination.deletingLastPathComponent())
        if replacingExistingRegularFile {
            var information = stat()
            let result = lstat(destination.path, &information)
            guard (result == 0
                    && information.st_mode & S_IFMT == S_IFREG
                    && information.st_uid == geteuid())
                    || (result != 0 && errno == ENOENT) else {
                throw HarcDesktopClientError.unsafePath
            }
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        if replacingExistingRegularFile {
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw HarcDesktopClientError.storageFailure
            }
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        published = true
        let directory = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC
        )
        guard directory >= 0 else { throw HarcDesktopClientError.storageFailure }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else {
            throw HarcDesktopClientError.storageFailure
        }
    }

    static func removeProtectedRegularFileIfPresent(_ url: URL) throws {
        guard url.isFileURL,
              url.standardizedFileURL == url,
              url.deletingLastPathComponent().standardizedFileURL
                == url.deletingLastPathComponent() else {
            throw HarcDesktopClientError.unsafePath
        }
        try validateOwnedDirectory(url.deletingLastPathComponent())
        var information = stat()
        let result = lstat(url.path, &information)
        if result != 0, errno == ENOENT { return }
        guard result == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid() else {
            throw HarcDesktopClientError.unsafePath
        }
        try FileManager.default.removeItem(at: url)
        let directory = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw HarcDesktopClientError.storageFailure
        }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else {
            throw HarcDesktopClientError.storageFailure
        }
    }

    private struct WAVLayout { let dataOffset: Int; let dataBytes: Int }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid() else {
            throw HarcDesktopClientError.unsafePath
        }
    }

    private static func wavLayout(_ bytes: Data) throws -> WAVLayout {
        var cursor = 12
        var formatValid = false
        var dataLayout: WAVLayout?
        while cursor + 8 <= bytes.count {
            let id = Data(bytes[cursor ..< cursor + 4])
            let size = Int(littleEndianUInt32(bytes, at: cursor + 4))
            let body = cursor + 8
            guard size >= 0, body <= bytes.count else {
                throw HarcDesktopClientError.invalidWAV
            }
            if id == Data("fmt ".utf8) {
                guard size >= 16, body + 16 <= bytes.count,
                      littleEndianUInt16(bytes, at: body) == 1,
                      littleEndianUInt16(bytes, at: body + 2) == 1,
                      littleEndianUInt32(bytes, at: body + 4) == 16_000,
                      littleEndianUInt16(bytes, at: body + 12) == 2,
                      littleEndianUInt16(bytes, at: body + 14) == 16 else {
                    throw HarcDesktopClientError.invalidWAV
                }
                formatValid = true
            } else if id == Data("data".utf8) {
                dataLayout = WAVLayout(dataOffset: body, dataBytes: size)
                break
            }
            let padded = size + (size & 1)
            guard body + padded > cursor else {
                throw HarcDesktopClientError.invalidWAV
            }
            cursor = body + padded
        }
        guard formatValid, let dataLayout else {
            throw HarcDesktopClientError.invalidWAV
        }
        return dataLayout
    }

    private static func littleEndianUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }

    private static func canonicalHeader(dataBytes: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        appendLittleEndian(dataBytes + 36, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt32(32_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataBytes, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { buffer in
            while written < data.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    data.count - written
                )
                guard result > 0 else { throw HarcDesktopClientError.storageFailure }
                written += result
            }
        }
    }
}

enum HarcDesktopClientError: LocalizedError {
    case installationIdentityLost
    case captureIdentityMismatch
    case missingDurableMaster
    case unsafePath
    case invalidWAV
    case destinationExists
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .installationIdentityLost:
            "The Desktop Client signing identity is missing; existing outbox recordings were left untouched."
        case .captureIdentityMismatch:
            "A durable Client capture belongs to another installation identity."
        case .missingDurableMaster:
            "A Client capture sidecar has no matching durable audio master."
        case .unsafePath:
            "The Desktop Client storage path is unsafe."
        case .invalidWAV:
            "The completed recording is not canonical 16 kHz mono PCM audio."
        case .destinationExists:
            "A Client capture destination already exists."
        case .storageFailure:
            "The Desktop Client could not durably store the recording."
        }
    }
}
