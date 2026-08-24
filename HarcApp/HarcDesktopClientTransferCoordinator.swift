import Combine
import CryptoKit
import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcCore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

/// Durable exponential retry state for recoverable Client-to-Host work.
/// The recording outbox remains the source of truth; this only controls when
/// the next self-healing inventory pass should run.
struct HarcDesktopRetrySchedule: Codable, Equatable {
    private static let delays: [TimeInterval] = [
        1, 2, 5, 10, 30, 60, 120, 300,
    ]

    private(set) var consecutiveFailures = 0
    private(set) var nextRetryAt: Date?

    mutating func recordFailure(
        now: Date,
        jitterMultiplier: Double = 1
    ) -> TimeInterval {
        consecutiveFailures = min(
            consecutiveFailures + 1,
            Self.delays.count
        )
        let base = Self.delays[consecutiveFailures - 1]
        let delay = base * min(1.15, max(0.85, jitterMultiplier))
        nextRetryAt = now.addingTimeInterval(delay)
        return delay
    }

    mutating func reset() {
        consecutiveFailures = 0
        nextRetryAt = nil
    }

    func remainingDelay(at now: Date) -> TimeInterval? {
        nextRetryAt.map { max(0, $0.timeIntervalSince(now)) }
    }
}

struct HarcDesktopHostContactEvidence: Codable, Equatable {
    enum Route: String, Codable {
        case direct
        case encryptedRelay = "encrypted-relay"
    }

    let authenticatedAt: Date
    let route: Route
    /// Binds display-only contact history to the exact adopted authority.
    /// Optional solely so pre-upgrade evidence decodes and is then ignored.
    let libraryID: String?
    let hostAuthorityID: String?
}

/// Binds a durable Client-side completion marker to the exact adopted Host.
/// A missing binding is intentionally not trusted: pre-upgrade markers remain
/// decodable, but are resubmitted after the next authenticated adoption.
struct HarcDesktopHostEvidenceBinding: Codable, Equatable, Sendable {
    let libraryID: String
    let hostAuthorityID: String

    init(trust: AdoptedTrustTuple) {
        libraryID = trust.libraryID.description
        hostAuthorityID = trust.hostAuthorityID.description
    }

    init(adoption: ValidatedClientAdoptionEvidence) {
        libraryID = adoption.hostTrust.libraryID.description
        hostAuthorityID = adoption.hostTrust.hostAuthorityID.description
    }

    func matches(_ trust: AdoptedTrustTuple?) -> Bool {
        guard let trust else { return false }
        return libraryID == trust.libraryID.description
            && hostAuthorityID == trust.hostAuthorityID.description
    }
}

@MainActor
final class HarcDesktopClientTransferCoordinator: ObservableObject {
    enum HostProbeState: Equatable, Sendable {
        case notChecked
        case checking
        case reachable
        case unavailable(String)
        case pairingRepairRequired(String)
    }

    enum State: Equatable {
        case idle
        case encoding(UUID)
        case waitingForPairing(pending: Int)
        case connecting(UUID)
        case uploading(UUID)
        case uploaded(UUID)
        case edgeArtifactDeferred(UUID, String)
        case retryNeeded(UUID, String)
        case securityBlocked(UUID, String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingProcessingCount = 0
    @Published private(set) var pendingSpeakerCount = 0
    @Published private(set) var speakerRepairCount = 0
    @Published private(set) var speakerReviewCount = 0
    @Published private(set) var hostProbeState: HostProbeState = .notChecked
    @Published private(set) var lastAuthenticatedContact:
        HarcDesktopHostContactEvidence?
    @Published private(set) var nextAutomaticRetryAt: Date? = nil

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let libraryCache: HarcLibraryCache
    private let locations: HarcMobileCaptureLocations
    private let clientRoot: URL
    private let routeURL: URL
    private let retryURL: URL
    private let contactURL: URL
    private let diagnosticLog: HarcDiagnosticLogStore
    private var queue: [HarcMobileFinalizedMaster] = []
    private var queuedOrigins = Set<OriginRecordingID>()
    /// Set by Client archive reconciliation. These origins remain fail-closed
    /// until a later successful inventory proves their local facts again.
    private var recoveryBlockedOrigins = Set<OriginRecordingID>()
    private var activeStages: [UUID: String] = [:]
    private var worker: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hostProbeTask: Task<Void, Never>?
    private var retrySchedule = HarcDesktopRetrySchedule()

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        libraryCache: HarcLibraryCache,
        clientRoot: URL,
        routeURL: URL,
        diagnosticLog: HarcDiagnosticLogStore
    ) throws {
        self.identity = identity
        self.store = store
        self.libraryCache = libraryCache
        self.clientRoot = clientRoot
        locations = try HarcMobileCaptureLocations(
            applicationSupportRoot: clientRoot
        )
        self.routeURL = routeURL
        retryURL = clientRoot.appendingPathComponent("host-retry.json")
        contactURL = clientRoot.appendingPathComponent("host-contact.json")
        self.diagnosticLog = diagnosticLog
        if let data = try? Data(contentsOf: retryURL, options: .mappedIfSafe),
           let persisted = try? JSONDecoder().decode(
               HarcDesktopRetrySchedule.self,
               from: data
           ) {
            retrySchedule = persisted
            nextAutomaticRetryAt = persisted.nextRetryAt
        }
        if let data = try? Data(
            contentsOf: contactURL,
            options: .mappedIfSafe
        ) {
            lastAuthenticatedContact = try? JSONDecoder().decode(
                HarcDesktopHostContactEvidence.self,
                from: data
            )
        }
    }

    var statusMessage: String {
        switch state {
        case .idle:
            if case .pairingRepairRequired(let message) = hostProbeState {
                message
            } else if case .unavailable = hostProbeState {
                "Host is unavailable; local capture remains ready"
            } else if pendingCount > 0 {
                "\(pendingCount) recording(s) waiting for Host"
            } else if pendingProcessingCount + pendingSpeakerCount > 0 {
                "\(pendingProcessingCount + pendingSpeakerCount) Host update(s) waiting"
            } else if speakerRepairCount > 0 {
                "\(speakerRepairCount) local speaker pass(es) retrying"
            } else if speakerReviewCount > 0 {
                "\(speakerReviewCount) speaker match(es) need review"
            } else {
                "Client storage ready"
            }
        case .encoding:
            "Compressing a recording for Host"
        case .waitingForPairing(let pending):
            if pendingCount > 0 {
                "\(pendingCount) recording(s) waiting for Host pairing"
            } else {
                "\(pending) processing or speaker update(s) waiting for Host pairing"
            }
        case .connecting:
            "Connecting securely to Host"
        case .uploading:
            "Uploading a recording to Host"
        case .uploaded:
            if pendingCount > 0 {
                "\(pendingCount) recording(s) still waiting for Host"
            } else if pendingProcessingCount + pendingSpeakerCount > 0 {
                "Audio is safe on Host; local updates are still syncing"
            } else {
                "All Client recordings and updates are on Host"
            }
        case .edgeArtifactDeferred(_, let message):
            "Audio is safe on Host; local metadata handoff will retry: \(message)"
        case .retryNeeded(_, let message):
            "Host transfer needs retry: \(message)"
        case .securityBlocked(_, let message):
            "Host transfer blocked for security: \(message)"
        }
    }

    func retryPending() {
        hostProbeTask?.cancel()
        hostProbeTask = nil
        retryTask?.cancel()
        retryTask = nil
        retrySchedule.reset()
        nextAutomaticRetryAt = nil
        persistRetrySchedule()
        inventoryPending()
    }

    /// A newly persisted adoption is the only event allowed to clear a
    /// terminal pairing-repair probe result.
    func hostAdoptionDidChange() {
        hostProbeState = .notChecked
        retryPending()
    }

    /// Restores pending work at launch without erasing the durable failure
    /// count. A failed first attempt therefore continues the bounded backoff
    /// instead of restarting a tight retry loop after every app relaunch.
    func resumePending() {
        retryTask?.cancel()
        retryTask = nil
        if let delay = retrySchedule.remainingDelay(at: Date()), delay > 0 {
            nextAutomaticRetryAt = retrySchedule.nextRetryAt
            diagnosticLog.append(
                severity: .info,
                area: "transfer",
                stage: "retry-restored",
                message: "Saved Host retry backoff remains active",
                context: [
                    "attempt": String(retrySchedule.consecutiveFailures),
                    "delay_seconds": String(Int(delay.rounded(.up))),
                ]
            )
            scheduleInventory(after: delay)
            return
        }
        nextAutomaticRetryAt = nil
        inventoryPending()
    }

    /// Performs a lightweight authenticated session check only while no
    /// transfer is active. It verifies trust, repairs a stale direct route, and
    /// closes immediately; capture and durable outbox work always take
    /// precedence over this presentation/health signal.
    func probeHostIfIdle() {
        guard hostProbeTask == nil,
              worker == nil,
              queue.isEmpty,
              !Self.hasPendingWork(
                  recordings: pendingCount,
                  processing: pendingProcessingCount,
                  speakers: pendingSpeakerCount
              ),
              !Self.probeIsTerminal(hostProbeState) else { return }
        hostProbeState = .checking
        hostProbeTask = Task { [weak self] in
            await self?.performHostProbe()
        }
    }

    nonisolated static func probeIsTerminal(_ state: HostProbeState) -> Bool {
        if case .pairingRepairRequired = state { return true }
        return false
    }

    private func performHostProbe() async {
        defer { hostProbeTask = nil }
        do {
            let opened = try await HarcDesktopHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
            do {
                recordAuthenticatedContact(
                    route: opened.path,
                    adoption: opened.adoption
                )
                try await opened.connection.shutdownGracefully()
                hostProbeState = .reachable
                diagnosticLog.append(
                    severity: .success,
                    area: "connection",
                    stage: "idle-health-authenticated",
                    message: "Idle Host health check authenticated",
                    context: ["route": Self.routeName(opened.path)]
                )
            } catch {
                await opened.connection.shutdownImmediately()
                throw error
            }
        } catch is CancellationError {
            hostProbeState = .notChecked
        } catch HarcDesktopHostConnectionError.notPaired {
            hostProbeState = .notChecked
        } catch HarcDesktopHostConnectionError.pairingRepairRequired {
            let message = HarcDesktopHostConnectionError
                .pairingRepairRequired.localizedDescription
            hostProbeState = .pairingRepairRequired(message)
            diagnosticLog.append(
                severity: .warning,
                area: "connection",
                stage: "idle-health-pairing-repair",
                message: message
            )
        } catch {
            let message = privacyBounded(
                HarcTransportErrorDiagnostic.describe(error).summary
            )
            hostProbeState = .unavailable(message)
            diagnosticLog.append(
                severity: .info,
                area: "connection",
                stage: "idle-health-unavailable",
                message: message
            )
        }
    }

    private func inventoryPending() {
        do {
            let activeTrust = try store.activeAdoption()?.tuple
            let outboxes = try store.recordingOutboxes()
            let eligibleOutboxes = outboxes.filter { outbox in
                !recoveryBlockedOrigins.contains(
                    outbox.finalizedCapture.capture.originRecordingID
                )
                    && outbox.stateMachine.state != .securityBlocked
                    && outbox.integrityBlock == nil
                    && outbox.finalizedCapture.masterFileState == .present
            }
            let pending = eligibleOutboxes.filter { outbox in
                outbox.stateMachine.state != .securityBlocked && (
                    outbox.stateMachine.state != .committed
                        || Self.needsProcessingArtifact(
                            origin: outbox.finalizedCapture.capture
                                .originRecordingID,
                            clientRoot: clientRoot,
                            expectedTrust: activeTrust
                        )
                        || Self.needsSpeakerObservations(
                            origin: outbox.finalizedCapture.capture
                                .originRecordingID,
                            clientRoot: clientRoot,
                            expectedTrust: activeTrust
                        )
                )
            }
            pendingCount = pending.filter {
                $0.stateMachine.state != .committed
            }.count
            pendingProcessingCount = pending.filter {
                Self.needsProcessingArtifact(
                    origin: $0.finalizedCapture.capture.originRecordingID,
                    clientRoot: clientRoot,
                    expectedTrust: activeTrust
                )
            }.count
            pendingSpeakerCount = pending.filter {
                Self.needsSpeakerObservations(
                    origin: $0.finalizedCapture.capture.originRecordingID,
                    clientRoot: clientRoot,
                    expectedTrust: activeTrust
                )
            }.count
            speakerRepairCount = Self.speakerRepairCount(
                outboxes: eligibleOutboxes,
                clientRoot: clientRoot
            )
            speakerReviewCount = Self.speakerReviewCount(
                outboxes: eligibleOutboxes,
                clientRoot: clientRoot,
                expectedTrust: activeTrust
            )
            diagnosticLog.append(
                severity: pending.isEmpty ? .success : .info,
                area: "transfer",
                stage: "queue-inventory",
                message: pending.isEmpty
                    ? "No recordings need Host transfer"
                    : "Queued recoverable recordings for Host transfer",
                context: ["pending": String(pending.count)]
            )
            for outbox in pending {
                let master = try Self.master(from: outbox.finalizedCapture)
                guard queuedOrigins.insert(master.originRecordingID).inserted
                else { continue }
                queue.append(master)
            }
            if pending.isEmpty {
                state = .idle
                clearAutomaticRetry()
            }
            startWorkerIfNeeded()
        } catch {
            logFailure(error, stage: "queue-inventory", recording: nil)
            state = .retryNeeded(UUID(), error.localizedDescription)
            scheduleAutomaticRetry(reason: "queue-inventory")
        }
    }

    func setRecoveryBlockedOrigins(_ origins: Set<OriginRecordingID>) {
        recoveryBlockedOrigins = origins
        queue.removeAll { origins.contains($0.originRecordingID) }
        queuedOrigins.subtract(origins)
    }

    func shutdown() {
        worker?.cancel()
        worker = nil
        hostProbeTask?.cancel()
        hostProbeTask = nil
        retryTask?.cancel()
        retryTask = nil
        queue.removeAll()
        queuedOrigins.removeAll()
        state = .idle
        hostProbeState = .notChecked
    }

    /// Clears display and retry state only after the adoption and route have
    /// been removed. Durable recordings and their outboxes are untouched.
    func forgetHostState() {
        shutdown()
        lastAuthenticatedContact = nil
        retrySchedule.reset()
        nextAutomaticRetryAt = nil
        pendingProcessingCount = 0
        pendingSpeakerCount = 0
        speakerRepairCount = 0
        speakerReviewCount = 0
        hostProbeState = .notChecked
        for url in [contactURL, retryURL] {
            do {
                try HarcDesktopClientFiles.removeProtectedRegularFileIfPresent(
                    url
                )
            } catch {
                diagnosticLog.append(
                    severity: .warning,
                    area: "connection",
                    stage: "forget-local-state",
                    message: "Forgotten Host display state could not be removed",
                    context: [
                        "error_type": String(reflecting: Swift.type(of: error)),
                    ]
                )
            }
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        defer { worker = nil }
        while !queue.isEmpty {
            guard !Task.isCancelled else { return }
            let master = queue.removeFirst()
            do {
                let artifactFailure = try await transfer(master)
                activeStages.removeValue(
                    forKey: master.originRecordingID.recordingUUID
                )
                queuedOrigins.remove(master.originRecordingID)
                refreshPendingBreakdown()
                if let artifactFailure {
                    state = .edgeArtifactDeferred(
                        master.originRecordingID.recordingUUID,
                        artifactFailure
                    )
                    scheduleAutomaticRetry(reason: "derived-artifact")
                } else {
                    state = .uploaded(
                        master.originRecordingID.recordingUUID
                    )
                }
            } catch HarcDesktopClientTransferError.notPaired {
                activeStages.removeValue(
                    forKey: master.originRecordingID.recordingUUID
                )
                queuedOrigins.remove(master.originRecordingID)
                refreshPendingBreakdown()
                state = .waitingForPairing(
                    pending: max(
                        1,
                        pendingCount + pendingProcessingCount
                            + pendingSpeakerCount
                    )
                )
                return
            } catch is CancellationError {
                activeStages.removeValue(
                    forKey: master.originRecordingID.recordingUUID
                )
                queuedOrigins.remove(master.originRecordingID)
                return
            } catch HarcDesktopHostConnectionError.pairingRepairRequired {
                activeStages.removeValue(
                    forKey: master.originRecordingID.recordingUUID
                )
                queuedOrigins.remove(master.originRecordingID)
                refreshPendingBreakdown()
                let message = HarcDesktopHostConnectionError
                    .pairingRepairRequired.localizedDescription
                logFailure(
                    HarcDesktopHostConnectionError.pairingRepairRequired,
                    stage: "pairing-repair-required",
                    recording: master.originRecordingID.recordingUUID
                )
                state = .securityBlocked(
                    master.originRecordingID.recordingUUID,
                    message
                )
                // This cannot heal by hammering the same rejected grant.
                // Durable outboxes remain untouched and a successful re-pair
                // explicitly restarts their inventory.
                clearAutomaticRetry()
                return
            } catch {
                logFailure(
                    error,
                    stage: activeStages[
                        master.originRecordingID.recordingUUID
                    ] ?? "transfer",
                    recording: master.originRecordingID.recordingUUID
                )
                activeStages.removeValue(
                    forKey: master.originRecordingID.recordingUUID
                )
                queuedOrigins.remove(master.originRecordingID)
                let outbox = try? store.recordingOutbox(
                    for: master.originRecordingID
                )
                if outbox?.stateMachine.state == .securityBlocked {
                    state = .securityBlocked(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                } else {
                    state = .retryNeeded(
                        master.originRecordingID.recordingUUID,
                        error.localizedDescription
                    )
                    scheduleAutomaticRetry(reason: "transfer")
                }
                return
            }
        }
        if !Self.hasPendingWork(
            recordings: pendingCount,
            processing: pendingProcessingCount,
            speakers: pendingSpeakerCount
        ) {
            clearAutomaticRetry()
        }
    }

    private func refreshPendingBreakdown() {
        guard let outboxes = try? store.recordingOutboxes() else { return }
        let activeAdoption = try? store.activeAdoption()
        let activeTrust = activeAdoption?.tuple
        let transferable = outboxes.filter { outbox in
            !recoveryBlockedOrigins.contains(
                outbox.finalizedCapture.capture.originRecordingID
            )
                && outbox.stateMachine.state != .securityBlocked
                && outbox.integrityBlock == nil
                && outbox.finalizedCapture.masterFileState == .present
        }
        pendingCount = transferable.filter {
            $0.stateMachine.state != .committed
        }.count
        pendingProcessingCount = transferable.filter {
            Self.needsProcessingArtifact(
                origin: $0.finalizedCapture.capture.originRecordingID,
                clientRoot: clientRoot,
                expectedTrust: activeTrust
            )
        }.count
        pendingSpeakerCount = transferable.filter {
            Self.needsSpeakerObservations(
                origin: $0.finalizedCapture.capture.originRecordingID,
                clientRoot: clientRoot,
                expectedTrust: activeTrust
            )
        }.count
        speakerRepairCount = Self.speakerRepairCount(
            outboxes: outboxes,
            clientRoot: clientRoot
        )
        speakerReviewCount = Self.speakerReviewCount(
            outboxes: outboxes,
            clientRoot: clientRoot,
            expectedTrust: activeTrust
        )
    }

    nonisolated static func hasPendingWork(
        recordings: Int,
        processing: Int,
        speakers: Int
    ) -> Bool {
        recordings > 0 || processing > 0 || speakers > 0
    }

    private func scheduleAutomaticRetry(reason: String) {
        retryTask?.cancel()
        let delay = retrySchedule.recordFailure(
            now: Date(),
            jitterMultiplier: Double.random(in: 0.85...1.15)
        )
        nextAutomaticRetryAt = retrySchedule.nextRetryAt
        persistRetrySchedule()
        diagnosticLog.append(
            severity: .info,
            area: "transfer",
            stage: "retry-scheduled",
            message: "Recoverable Host work will retry automatically",
            context: [
                "attempt": String(retrySchedule.consecutiveFailures),
                "delay_seconds": String(Int(delay.rounded())),
                "reason": reason,
            ]
        )
        scheduleInventory(after: delay)
    }

    private func scheduleInventory(after delay: TimeInterval) {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.retryTask = nil
            self.nextAutomaticRetryAt = nil
            self.inventoryPending()
        }
    }

    private func clearAutomaticRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextAutomaticRetryAt = nil
        guard retrySchedule.consecutiveFailures != 0
                || retrySchedule.nextRetryAt != nil else { return }
        retrySchedule.reset()
        persistRetrySchedule()
    }

    private func persistRetrySchedule() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(retrySchedule),
                to: retryURL,
                replacingExistingRegularFile: true
            )
        } catch {
            diagnosticLog.append(
                severity: .warning,
                area: "transfer",
                stage: "retry-persistence",
                message: "Automatic retry state could not be saved",
                context: [
                    "error_type": String(reflecting: Swift.type(of: error)),
                ]
            )
        }
    }

    private func transfer(
        _ master: HarcMobileFinalizedMaster
    ) async throws -> String? {
        let alreadyCommitted = try store.recordingOutbox(
            for: master.originRecordingID
        )?.stateMachine.state == .committed
        let artifacts: [HarcMobileEncodedChunkArtifact]
        if alreadyCommitted {
            // Artifact-only retries must not re-encode or replay audio that the
            // Host has already committed and acknowledged.
            artifacts = []
        } else {
            state = .encoding(master.originRecordingID.recordingUUID)
            activeStages[master.originRecordingID.recordingUUID] = "encode"
            diagnosticLog.append(
                severity: .info,
                area: "transfer",
                stage: "encode",
                message: "Preparing lossless chunks from the protected master",
                context: recordingContext(master.originRecordingID.recordingUUID)
            )
            let locations = locations
            artifacts = try await Task.detached(priority: .utility) {
                try HarcMobileALACChunkEncoder().encode(
                    master,
                    locations: locations
                )
            }.value
            diagnosticLog.append(
                severity: .success,
                area: "transfer",
                stage: "encode",
                message: "Lossless chunks are ready",
                context: recordingContext(
                    master.originRecordingID.recordingUUID,
                    extra: [
                        "chunks": String(artifacts.count),
                        "bytes": String(
                            artifacts.reduce(UInt64(0)) {
                                $0 + $1.encodedByteLength
                            }
                        ),
                    ]
                )
            )
        }

        state = .connecting(master.originRecordingID.recordingUUID)
        activeStages[master.originRecordingID.recordingUUID] = "connection-open"
        diagnosticLog.append(
            severity: .info,
            area: "connection",
            stage: "open",
            message: "Authenticating an adopted Host route",
            context: recordingContext(master.originRecordingID.recordingUUID)
        )
        let opened: HarcDesktopOpenedHostConnection
        do {
            opened = try await HarcDesktopHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
        } catch HarcDesktopHostConnectionError.notPaired {
            throw HarcDesktopClientTransferError.notPaired
        }
        diagnosticLog.append(
            severity: .success,
            area: "connection",
            stage: "authenticated",
            message: "Pinned Host session is ready",
            context: recordingContext(
                master.originRecordingID.recordingUUID,
                extra: ["route": Self.routeName(opened.path)]
            )
        )
        recordAuthenticatedContact(
            route: opened.path,
            adoption: opened.adoption
        )
        let connection = opened.connection
        do {
            if alreadyCommitted {
                guard let receipt = try store.verifiedRecordingReceipt(
                    for: master.originRecordingID
                ) else {
                    throw HarcDesktopClientTransferError.missingVerifiedReceipt
                }
                let artifactFailure = try await submitProcessingArtifactIfPresent(
                    origin: master.originRecordingID,
                    opened: opened
                )
                let speakerFailure = try await submitSpeakerObservationsIfPresent(
                    origin: master.originRecordingID,
                    canonicalID: receipt.canonicalRecordingID,
                    opened: opened
                )
                try await connection.shutdownGracefully()
                return Self.combinedDeferredMessage(
                    artifactFailure,
                    speakerFailure
                )
            }
            let profile = try Self.frozenProfile(
                negotiated: opened.negotiated
            )
            let outbox = try store.recordingOutbox(
                for: master.originRecordingID
            )
            let existingIntent = try store.uploadBeginIntent(
                for: master.originRecordingID
            )
            let uploadID = existingIntent?.intent.uploadID
                ?? outbox?.uploadID
                ?? .random()
            let chunks = try artifacts.map { artifact in
                let descriptor = try LogicalChunkDescriptor(
                    originRecordingID: master.originRecordingID,
                    chunkID: Self.chunkID(
                        origin: master.originRecordingID,
                        index: artifact.chunkIndex
                    ),
                    chunkIndex: artifact.chunkIndex,
                    canonicalStartFrame: artifact.canonicalStartFrame,
                    canonicalFrameCount: artifact.canonicalFrameCount,
                    encoding: .cafALAC,
                    encodedByteLength: artifact.encodedByteLength,
                    encodedSHA256: try EncodedChunkSHA256(
                        artifact.encodedSHA256
                    ),
                    canonicalDecodedByteLength:
                        artifact.canonicalDecodedByteLength,
                    canonicalDecodedSHA256: try CanonicalPCMHash(
                        artifact.canonicalDecodedSHA256
                    )
                )
                return try HarcForegroundEncodedChunk(
                    descriptor: descriptor,
                    encodedFileURL: artifact.encodedFileURL
                )
            }
            let plan = try HarcForegroundRecordingUploadPlan(
                trustTuple: AdoptedTrustTuple(
                    libraryID: opened.adoption.hostTrust.libraryID,
                    hostAuthorityID:
                        opened.adoption.hostTrust.hostAuthorityID
                ),
                uploadID: uploadID,
                originRecordingID: master.originRecordingID,
                frozenProfile: profile,
                chunks: chunks
            )
            state = .uploading(master.originRecordingID.recordingUUID)
            let uploader = HarcForegroundRecordingOutboxCoordinator(
                store: store,
                transport: connection,
                diagnosticSink: { [weak self] event in
                    await self?.record(
                        event,
                        recording: master.originRecordingID.recordingUUID,
                        uploadID: uploadID,
                        route: opened.path
                    )
                }
            )
            let receipt = try await uploader.drive(
                plan,
                openedSession: opened.session,
                deviceSigner: identity
            )
            let artifactFailure = try await submitProcessingArtifactIfPresent(
                origin: master.originRecordingID,
                opened: opened
            )
            let speakerFailure = try await submitSpeakerObservationsIfPresent(
                origin: master.originRecordingID,
                canonicalID: receipt.canonicalRecordingID,
                opened: opened
            )
            try await connection.shutdownGracefully()
            diagnosticLog.append(
                severity: .success,
                area: "transfer",
                stage: "complete",
                message: "Recording transfer and verified receipt completed",
                context: recordingContext(
                    master.originRecordingID.recordingUUID,
                    extra: [
                        "route": Self.routeName(opened.path),
                        "upload": Self.short(uploadID.rawValue.uuidString),
                    ]
                )
            )
            return Self.combinedDeferredMessage(
                artifactFailure,
                speakerFailure
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private func record(
        _ event: HarcForegroundUploadDiagnosticEvent,
        recording: UUID,
        uploadID: UploadID,
        route: HarcVerifiedRoutePath
    ) {
        activeStages[recording] = event.stage.rawValue
        var extra = [
            "route": Self.routeName(route),
            "upload": Self.short(uploadID.rawValue.uuidString),
            "chunks": String(event.chunkCount),
        ]
        if let index = event.chunkIndex {
            extra["chunk"] = "\(index + 1)/\(event.chunkCount)"
        }
        if let bytes = event.encodedByteCount {
            extra["bytes"] = String(bytes)
        }
        diagnosticLog.append(
            severity: event.stage == .chunkDurable
                || event.stage == .receiptDurable ? .success : .info,
            area: "transfer",
            stage: event.stage.rawValue,
            message: event.message,
            context: recordingContext(recording, extra: extra)
        )
    }

    private func logFailure(
        _ error: any Error,
        stage: String,
        recording: UUID?
    ) {
        let diagnostic = HarcTransportErrorDiagnostic.describe(error)
        var context = ["error_type": diagnostic.type]
        if let recording {
            context["recording"] = Self.short(recording.uuidString)
        }
        if let code = diagnostic.rpcCode { context["rpc_code"] = code }
        if let number = diagnostic.rpcCodeNumber {
            context["rpc_number"] = String(number)
        }
        if let cause = diagnostic.cause {
            context["cause"] = privacyBounded(cause)
        }
        if let routeFailure = error as? HarcDesktopHostRouteFailure {
            context["direct_error"] = privacyBounded(
                HarcTransportErrorDiagnostic.describe(
                    routeFailure.directError
                ).summary
            )
            if let relayError = routeFailure.relayError {
                context["relay_error"] = privacyBounded(
                    HarcTransportErrorDiagnostic.describe(relayError).summary
                )
            }
        }
        diagnosticLog.append(
            severity: .error,
            area: "transfer",
            stage: stage,
            message: privacyBounded(diagnostic.summary),
            context: context
        )
    }

    private func recordingContext(
        _ recording: UUID,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var result = extra
        result["recording"] = Self.short(recording.uuidString)
        return result
    }

    private func privacyBounded(_ value: String) -> String {
        value
            .replacingOccurrences(of: clientRoot.path, with: "<ClientState>")
            .replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path,
                with: "<Home>"
            )
    }

    private static func short(_ value: String) -> String {
        String(value.lowercased().prefix(8))
    }

    private static func routeName(_ path: HarcVerifiedRoutePath) -> String {
        switch path {
        case .direct: "direct"
        case .encryptedRelay: "encrypted-relay"
        }
    }

    private func recordAuthenticatedContact(
        route: HarcVerifiedRoutePath,
        adoption: ValidatedClientAdoptionEvidence
    ) {
        let evidence = HarcDesktopHostContactEvidence(
            authenticatedAt: Date(),
            route: route == .direct ? .direct : .encryptedRelay,
            libraryID: adoption.hostTrust.libraryID.description,
            hostAuthorityID: adoption.hostTrust.hostAuthorityID.description
        )
        lastAuthenticatedContact = evidence
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(evidence),
                to: contactURL,
                replacingExistingRegularFile: true
            )
        } catch {
            diagnosticLog.append(
                severity: .warning,
                area: "connection",
                stage: "contact-persistence",
                message: "Authenticated Host contact could not be saved",
                context: [
                    "error_type": String(reflecting: Swift.type(of: error)),
                ]
            )
        }
    }

    private func submitSpeakerObservationsIfPresent(
        origin: OriginRecordingID,
        canonicalID: CanonicalRecordingID,
        opened: HarcDesktopOpenedHostConnection
    ) async throws -> String? {
        do {
            let sidecarURL = Self.captureSidecarURL(
                origin: origin,
                clientRoot: clientRoot
            )
            let sidecar = try JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: Data(contentsOf: sidecarURL, options: .mappedIfSafe)
            )
            let embeddings = sidecar.speakerEmbeddings ?? []
            guard !embeddings.isEmpty else { return nil }
            guard opened.adoption.grant.scopes.contains(
                .speakerObservationWrite
            ) else {
                throw HarcDesktopClientTransferError.speakerScopeNotGranted
            }

            let authorization = try HarcLibraryAuthorization(
                openedSession: opened.session
            )
            var pack: SpeakerRecognitionPack? = try libraryCache
                .speakerRecognitionPack(
                    libraryID: opened.adoption.hostTrust.libraryID
                )
            if opened.adoption.grant.scopes.contains(.speakerIdentityRead) {
                var packRequest = Harc_V1_GetSpeakerRecognitionPackRequestV1()
                packRequest.protocol = HarcProtocolVersion.v1.protobufV1()
                if let pack {
                    packRequest.afterRevision = pack.revision.rawValue
                }
                let response = try await opened.connection
                    .getSpeakerRecognitionPack(
                        packRequest,
                        authorization: authorization
                    )
                try Self.validateLibraryProtocol(
                    response.hasProtocol,
                    response.protocol
                )
                guard response.unchanged != response.hasPack else {
                    throw HarcDesktopClientTransferError
                        .malformedSpeakerResponse
                }
                if response.hasPack {
                    let refreshed = try response.pack.domainValue()
                    try libraryCache.persistSpeakerRecognitionPack(
                        refreshed,
                        libraryID: opened.adoption.hostTrust.libraryID
                    )
                    pack = refreshed
                }
            }

            var decisions: [HarcDesktopSpeakerDecisionRecord] = []
            for row in embeddings {
                guard row.speakerIndex >= 0,
                      row.totalMs > 0,
                      row.segmentCount > 0 else { continue }
                let quantized = try QuantizedSpeakerEmbedding.quantizing(
                    row.vector
                )
                let match = pack.flatMap {
                    SpeakerRecognitionMatcher.bestMatch(
                        embedding: quantized,
                        modelID: "wespeaker_v2",
                        pack: $0
                    )
                }
                let observation = try SpeakerEmbeddingObservation(
                    operationID: Self.observationOperationID(
                        origin: origin,
                        speakerIndex: row.speakerIndex,
                        packRevision: pack?.revision
                    ),
                    canonicalRecordingID: canonicalID,
                    speakerIndex: UInt32(row.speakerIndex),
                    embedding: quantized,
                    modelID: "wespeaker_v2",
                    speechDurationMs: UInt64(row.totalMs),
                    segmentCount: UInt32(row.segmentCount),
                    sourcePackRevision: match?.packRevision ?? pack?.revision,
                    proposedPersonID: match?.personID,
                    proposedScore: match?.score
                )
                var request = Harc_V1_SubmitSpeakerObservationRequestV1()
                request.protocol = HarcProtocolVersion.v1.protobufV1()
                request.observation = Harc_V1_SpeakerEmbeddingObservationV1(
                    observation
                )
                let response = try await opened.connection
                    .submitSpeakerObservation(
                        request,
                        authorization: authorization
                    )
                try Self.validateLibraryProtocol(
                    response.hasProtocol,
                    response.protocol
                )
                guard response.hasDecision else {
                    throw HarcDesktopClientTransferError
                        .malformedSpeakerResponse
                }
                let decision = try response.decision.domainValue()
                guard decision.operationID == observation.operationID,
                      decision.recognitionPackRevision
                        >= (observation.sourcePackRevision
                            ?? decision.recognitionPackRevision) else {
                    throw HarcDesktopClientTransferError
                        .malformedSpeakerResponse
                }
                decisions.append(HarcDesktopSpeakerDecisionRecord(
                    speakerIndex: row.speakerIndex,
                    decision: decision
                ))
            }

            let acceptedAt = Date()
            let hasConcerns = decisions.contains {
                $0.decision.disposition != .matched
            }
            let marker = HarcDesktopSpeakerObservationMarker(
                canonicalRecordingID: canonicalID,
                sourcePackRevision: pack?.revision,
                decisions: decisions,
                acceptedAt: acceptedAt,
                nextReviewAt: hasConcerns
                    ? acceptedAt.addingTimeInterval(6 * 60 * 60)
                    : nil,
                hostBinding: HarcDesktopHostEvidenceBinding(
                    adoption: opened.adoption
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(marker),
                to: Self.speakerObservationMarkerURL(
                    origin: origin,
                    clientRoot: clientRoot
                ),
                replacingExistingRegularFile: true
            )
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return error.localizedDescription
        }
    }

    private func submitProcessingArtifactIfPresent(
        origin: OriginRecordingID,
        opened: HarcDesktopOpenedHostConnection
    ) async throws -> String? {
        do {
            guard let submission = try durableProcessingSubmission(
                origin: origin,
                adoption: opened.adoption
            ) else { return nil }
            let authorization = try HarcProcessingAuthorization(
                openedSession: opened.session
            )
            let requests = HarcDesktopProcessingArtifactBuilder.requests(
                for: submission
            )
            let response = try await opened.connection.submitOwnArtifact(
                authorization: authorization,
                requestProducer: { writer in
                    for request in requests {
                        try Task.checkCancellation()
                        try await writer.write(request)
                    }
                }
            )
            guard response.hasProtocol,
                  response.protocol.major == 1,
                  response.protocol.minor
                    == opened.negotiated.protocolVersion.minor,
                  response.disposition
                    != Harc_V1_ProcessingSubmissionDispositionV1
                        .processingSubmissionDispositionUnspecified else {
                throw HarcDesktopClientTransferError.malformedProcessingResponse
            }
            let marker = HarcDesktopProcessingMarker(
                exactSignedMetadataSHA256: Data(
                    SHA256.hash(data: submission.exactSignedMetadata)
                ),
                disposition: response.disposition.rawValue,
                acceptedAt: Date(),
                hostBinding: HarcDesktopHostEvidenceBinding(
                    adoption: opened.adoption
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try HarcDesktopClientFiles.writeProtectedData(
                encoder.encode(marker),
                to: Self.processingMarkerURL(
                    origin: origin,
                    clientRoot: clientRoot
                ),
                replacingExistingRegularFile: true
            )
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return error.localizedDescription
        }
    }

    private func durableProcessingSubmission(
        origin: OriginRecordingID,
        adoption: ValidatedClientAdoptionEvidence
    ) throws -> HarcDesktopProcessingSubmission? {
        let url = Self.processingSubmissionURL(
            origin: origin,
            grantID: adoption.grant.grantID,
            grantEpoch: adoption.grant.registryEpoch,
            clientRoot: clientRoot
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let persisted = try JSONDecoder().decode(
                HarcDesktopProcessingSubmission.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
            guard !persisted.exactSignedMetadata.isEmpty,
                  persisted.exactSignedMetadata.count
                    <= HarcProtocolLimits.signedObjectBytes,
                  !persisted.exactBundle.isEmpty,
                  persisted.exactBundle.count
                    <= HarcProcessingBundleV1.maximumExactBytes else {
                throw HarcDesktopClientTransferError
                    .invalidDurableProcessingSubmission
            }
            return persisted
        }
        guard let submission = try HarcDesktopProcessingArtifactBuilder
            .makeSubmission(
                origin: origin,
                clientRoot: clientRoot,
                adoption: adoption,
                identity: identity
            ) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try HarcDesktopClientFiles.writeProtectedData(
            encoder.encode(submission),
            to: url
        )
        return submission
    }

    private static func needsProcessingArtifact(
        origin: OriginRecordingID,
        clientRoot: URL,
        expectedTrust: AdoptedTrustTuple?
    ) -> Bool {
        let marker = processingMarkerURL(origin: origin, clientRoot: clientRoot)
        if let data = try? Data(contentsOf: marker, options: .mappedIfSafe),
           let decoded = try? JSONDecoder().decode(
               HarcDesktopProcessingMarker.self,
               from: data
           ), decoded.hostBinding?.matches(expectedTrust) == true {
            return false
        }
        let sidecar = clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
        guard let data = try? Data(contentsOf: sidecar, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: data
              ) else { return false }
        return decoded.transcript != nil
    }

    private static func needsSpeakerObservations(
        origin: OriginRecordingID,
        clientRoot: URL,
        expectedTrust: AdoptedTrustTuple?,
        now: Date = Date()
    ) -> Bool {
        guard let data = try? Data(
            contentsOf: captureSidecarURL(
                origin: origin,
                clientRoot: clientRoot
            ),
            options: .mappedIfSafe
        ), let sidecar = try? JSONDecoder().decode(
            HarcDesktopClientCaptureSidecar.self,
            from: data
        ) else { return false }
        guard !(sidecar.speakerEmbeddings ?? []).isEmpty else { return false }

        let markerURL = speakerObservationMarkerURL(
            origin: origin,
            clientRoot: clientRoot
        )
        guard let markerData = try? Data(
            contentsOf: markerURL,
            options: .mappedIfSafe
        ), let marker = try? JSONDecoder().decode(
            HarcDesktopSpeakerObservationMarker.self,
            from: markerData
        ) else {
            return true
        }
        guard marker.hostBinding?.matches(expectedTrust) == true else {
            return true
        }
        return marker.needsReview(at: now)
    }

    private static func speakerReviewCount(
        outboxes: [StoredRecordingOutbox],
        clientRoot: URL,
        expectedTrust: AdoptedTrustTuple?
    ) -> Int {
        outboxes.reduce(into: 0) { count, outbox in
            let markerURL = speakerObservationMarkerURL(
                origin: outbox.finalizedCapture.capture.originRecordingID,
                clientRoot: clientRoot
            )
            guard let data = try? Data(
                contentsOf: markerURL,
                options: .mappedIfSafe
            ), let marker = try? JSONDecoder().decode(
                HarcDesktopSpeakerObservationMarker.self,
                from: data
            ), marker.hostBinding?.matches(expectedTrust) == true else {
                return
            }
            count += marker.concernCount
        }
    }

    private static func speakerRepairCount(
        outboxes: [StoredRecordingOutbox],
        clientRoot: URL
    ) -> Int {
        outboxes.reduce(into: 0) { count, outbox in
            let sidecarURL = captureSidecarURL(
                origin: outbox.finalizedCapture.capture.originRecordingID,
                clientRoot: clientRoot
            )
            guard let data = try? Data(
                contentsOf: sidecarURL,
                options: .mappedIfSafe
            ), let sidecar = try? JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: data
            ), sidecar.speakerProcessingNeedsRetry else { return }
            count += 1
        }
    }

    private static func captureSidecarURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
    }

    private static func speakerObservationMarkerURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).speakers-accepted.json"
            )
    }

    private static func processingMarkerURL(
        origin: OriginRecordingID,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).edge-accepted.json"
            )
    }

    private static func processingSubmissionURL(
        origin: OriginRecordingID,
        grantID: GrantID,
        grantEpoch: UInt64,
        clientRoot: URL
    ) -> URL {
        clientRoot
            .appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).edge-submission."
                    + "\(grantID.description).\(grantEpoch).json"
            )
    }

    private static func frozenProfile(
        negotiated: HarcValidatedNegotiatedCapabilitiesV1
    ) throws -> FrozenUploadProfile {
        let protocolVersion = try TransferProtocolVersion(
            minor: negotiated.protocolVersion.minor
        )
        let capabilities = try negotiated.selectedFeatureIDs
            .map(TransferCapabilityID.init)
            .sorted()
        let negotiatedDigest = try NegotiatedCapabilitiesSHA256(
            negotiated.exactSHA256
        )
        let provisional = try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                Data(repeating: 0, count: 32)
            ),
            purpose: .production
        )
        let exact = try HarcExactProtobufPayload(
            serializingOnce: Harc_V1_UploadProfileV1(provisional)
        )
        return try FrozenUploadProfile(
            protocolVersion: protocolVersion,
            encoding: negotiated.encoding,
            requiredCapabilities: capabilities,
            negotiatedCapabilitiesSHA256: negotiatedDigest,
            profileSHA256: try UploadProfileSHA256(
                HarcSignedEnvelopeV1.payloadDigest(exact.exactBytes)
            ),
            purpose: .production
        )
    }

    private static func chunkID(
        origin: OriginRecordingID,
        index: UInt32
    ) -> ChunkID {
        var input = Data("harc-desktop-chunk-id-v1".utf8)
        input.append(origin.deviceID.rawBytes)
        input.append(Data(origin.recordingUUID.uuidString.lowercased().utf8))
        var bigEndianIndex = index.bigEndian
        withUnsafeBytes(of: &bigEndianIndex) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return ChunkID(uuid)
    }

    private static func observationOperationID(
        origin: OriginRecordingID,
        speakerIndex: Int,
        packRevision: EntityRevision?
    ) -> OperationID {
        var input = Data("harc-desktop-speaker-observation-v2".utf8)
        input.append(origin.deviceID.rawBytes)
        input.append(Data(origin.recordingUUID.uuidString.lowercased().utf8))
        var index = Int64(speakerIndex).bigEndian
        withUnsafeBytes(of: &index) { input.append(contentsOf: $0) }
        var revision = (packRevision?.rawValue ?? 0).bigEndian
        withUnsafeBytes(of: &revision) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBufferPointer { buffer in
            UUID(uuidString: NSUUID(uuidBytes: buffer.baseAddress!).uuidString)!
        }
        return OperationID(uuid)
    }

    private static func validateLibraryProtocol(
        _ hasProtocol: Bool,
        _ value: Harc_V1_ProtocolVersionV1
    ) throws {
        guard hasProtocol,
              value.major == HarcProtocolVersion.v1.major,
              value.minor == HarcProtocolVersion.v1.minor else {
            throw HarcDesktopClientTransferError.malformedSpeakerResponse
        }
    }

    private static func combinedDeferredMessage(
        _ first: String?,
        _ second: String?
    ) -> String? {
        [first, second].compactMap { $0 }.nilIfEmpty?
            .joined(separator: " ")
    }

    private static func master(
        from stored: StoredFinalizedCapture
    ) throws -> HarcMobileFinalizedMaster {
        let capture = stored.capture
        let reason: HarcMobileCaptureFinalizationReason =
            switch capture.finalizationReason {
            case .userStopped: .userStopped
            case .systemEnded: .systemEnded
            case .recoveredDurablePrefix: .recoveredDurablePrefix
            case .storageExhausted: .storageExhausted
            case .writerFailure: .writerFailure
            }
        return try HarcMobileFinalizedMaster(
            producingDeviceID: capture.producingDeviceID,
            originRecordingID: capture.originRecordingID,
            masterFileURL: stored.masterFileURL,
            captureStartedAt: capture.captureStartedAt,
            captureEndedAt: capture.captureEndedAt,
            captureStartedMonotonicNanoseconds:
                capture.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                capture.captureEndedMonotonicNanoseconds,
            finalizationReason: reason,
            totalCanonicalFrames: capture.totalCanonicalFrames,
            canonicalPCMSHA256: capture.canonicalPCMSHA256,
            discontinuities: capture.discontinuities
        )
    }
}

private enum HarcDesktopClientTransferError: LocalizedError {
    case notPaired
    case malformedProcessingResponse
    case invalidDurableProcessingSubmission
    case missingVerifiedReceipt
    case speakerScopeNotGranted
    case malformedSpeakerResponse

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "The paired Harc Host is unavailable."
        case .malformedProcessingResponse:
            "The Host returned an invalid processing status."
        case .invalidDurableProcessingSubmission:
            "The saved processing submission is invalid."
        case .missingVerifiedReceipt:
            "The Host did not return a verified recording receipt."
        case .speakerScopeNotGranted:
            "This pairing predates shared speaker identity. Re-pair this Mac with the Host."
        case .malformedSpeakerResponse:
            "The Host returned invalid speaker identity data."
        }
    }
}

private struct HarcDesktopProcessingMarker: Codable, Sendable {
    let exactSignedMetadataSHA256: Data
    let disposition: Int
    let acceptedAt: Date
    let hostBinding: HarcDesktopHostEvidenceBinding?
}

struct HarcDesktopSpeakerObservationMarker: Codable, Sendable {
    let canonicalRecordingID: CanonicalRecordingID
    let sourcePackRevision: EntityRevision?
    let decisions: [HarcDesktopSpeakerDecisionRecord]?
    let acceptedAt: Date
    let nextReviewAt: Date?
    let hostBinding: HarcDesktopHostEvidenceBinding?

    init(
        canonicalRecordingID: CanonicalRecordingID,
        sourcePackRevision: EntityRevision?,
        decisions: [HarcDesktopSpeakerDecisionRecord]?,
        acceptedAt: Date,
        nextReviewAt: Date? = nil,
        hostBinding: HarcDesktopHostEvidenceBinding? = nil
    ) {
        self.canonicalRecordingID = canonicalRecordingID
        self.sourcePackRevision = sourcePackRevision
        self.decisions = decisions
        self.acceptedAt = acceptedAt
        self.nextReviewAt = nextReviewAt
        self.hostBinding = hostBinding
    }

    var concernCount: Int {
        decisions?.filter {
            $0.decision.disposition != .matched
        }.count ?? 0
    }

    func needsReview(at now: Date) -> Bool {
        guard concernCount > 0 else { return false }
        return (nextReviewAt ?? acceptedAt) <= now
    }
}

struct HarcDesktopSpeakerDecisionRecord: Codable, Sendable {
    let speakerIndex: Int
    let decision: SpeakerObservationDecision
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
