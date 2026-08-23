import AppKit
import Combine
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcRemoteTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HarcDesktopClientPairingWindowController:
    NSWindowController, NSWindowDelegate
{
    private let model: HarcDesktopClientPairingCoordinator

    init(model: HarcDesktopClientPairingCoordinator) {
        self.model = model
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: HarcDesktopClientPairingView(model: model)
            )
        )
        window.title = "Pair with Host"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 620))
        window.minSize = NSSize(width: 520, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}

@MainActor
final class HarcDesktopClientPairingCoordinator: ObservableObject {
    private static let pairingLog = Logger(
        subsystem: "com.harc.app",
        category: "DesktopPairing"
    )

    enum State: Equatable {
        case unpaired
        case reviewInvitation(
            host: String,
            fingerprint: String,
            expiresAt: Date
        )
        case connecting
        case compareWords(host: String, phrase: String, expiresAt: Date)
        case awaitingHostApproval(host: String, phrase: String)
        case paired(host: String)
        case failed(title: String, message: String)
    }

    private struct ActiveAttempt {
        let id: UUID
        let client: HarcBootstrapClient
        let connection: HarcPinnedGRPCConnection
        let ticket: PairingTicketV1
        let route: HarcDesktopHostRoute
        let presentation: HarcPairingClaimPresentation
    }

    @Published private(set) var state: State

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let routeURL: URL
    private let onAdopted: @MainActor () -> Void
    private let onForgetting: @MainActor () -> Void
    private var attempt: ActiveAttempt?
    private var reviewedPairingURI: String?
    /// Invalidates async continuations after close, rejection, or reset. An
    /// RPC that returns late can close its transport but cannot resurrect or
    /// approve an attempt the user has ended.
    private var operationGeneration: UInt64 = 0
    private var confirmingAttemptID: UUID?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL,
        hasActiveAdoption: Bool,
        onAdopted: @escaping @MainActor () -> Void = {},
        onForgetting: @escaping @MainActor () -> Void = {}
    ) {
        self.identity = identity
        self.store = store
        self.routeURL = routeURL
        self.onAdopted = onAdopted
        self.onForgetting = onForgetting
        state = hasActiveAdoption ? .paired(host: "Adopted Host") : .unpaired
    }

    func begin(pairingURI: String) async {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        reviewedPairingURI = nil
        guard HarcDesktopPairingCodeFilter.accepts(pairingURI) else {
            state = .failed(
                title: "Invalid Pairing Invitation",
                message: "This is not a Harc pairing invitation. Create a fresh Mac client invitation on the Host, then open or paste it here."
            )
            return
        }
        state = .connecting
        var connection: HarcPinnedGRPCConnection?
        var authenticatedPath: HarcVerifiedRoutePath?
        do {
            let nowMS = UInt64(Date().timeIntervalSince1970 * 1_000)
            let ticket = try PairingTicketV1.decodeURI(
                pairingURI,
                atUnixMilliseconds: nowMS
            )
            let route = try HarcDesktopHostRoute(ticket: ticket)
            let trust = try HarcTransportTrustCoordinator(
                pairingExactQRTransportSet: ticket.exactTransportObjectBytes,
                hostAuthorityPublicKey: ticket.hostAuthorityPublicKey
            )
            let policy = try HarcDesktopHostSessionConnector.capabilityPolicy()
            let expectation = try HarcBootstrapTrustExpectation(
                pairingTicket: ticket
            )
            let verified = try await HarcDesktopHostRouteConnector.openVerified(
                route: route,
                trust: trust
            ) { candidate in
                let verifier = HarcBootstrapClient(
                    rpc: candidate,
                    capabilityPolicy: policy,
                    sasDictionary: try HarcSASDictionaryV1.bundled()
                )
                return try await verifier.getHostInfo(
                    expectation: expectation
                )
            }
            guard operationGeneration == generation else {
                await verified.connection.shutdownImmediately()
                return
            }
            let opened = verified.connection
            connection = opened
            authenticatedPath = verified.path
            let client = HarcBootstrapClient(
                rpc: opened,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let presentation = try await client.beginPairing(
                ticket: ticket,
                deviceSigner: identity,
                requestedScopes: Self.requestedScopes(),
                deviceLabel: ProcessInfo.processInfo.hostName,
                verifiedHostInfo: verified.verification
            )
            guard operationGeneration == generation else {
                await opened.shutdownImmediately()
                return
            }
            attempt = ActiveAttempt(
                id: UUID(),
                client: client,
                connection: opened,
                ticket: ticket,
                route: route,
                presentation: presentation
            )
            state = .compareWords(
                host: presentation.hostDisplayName,
                phrase: presentation.sas.displayedPhrase,
                expiresAt: Date(
                    timeIntervalSince1970:
                        Double(presentation.expiresAtUnixMilliseconds) / 1_000
                )
            )
        } catch {
            if let connection { await connection.shutdownImmediately() }
            guard operationGeneration == generation else { return }
            Self.pairingLog.error(
                "Pairing failed after path=\(String(describing: authenticatedPath), privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public) detail=\(String(describing: error), privacy: .private)"
            )
            if let error = error as? HarcBootstrapClientError {
                state = .failed(
                    title: "Pairing Request Rejected",
                    message: error.localizedDescription
                )
            } else if let routeFailure = error as? HarcDesktopHostRouteFailure {
                let relayDetail = routeFailure.triedEncryptedRelay
                    ? "The direct route and the encrypted relay both failed before Harc could authenticate the Host."
                    : "The invitation did not include an encrypted relay route, and the direct route failed before Harc could authenticate the Host."
                state = .failed(
                    title: "Secure Host Connection Failed",
                    message: "\(relayDetail) Update Harc on both Macs, keep the Host pairing window open, and create a fresh Mac client invitation. No device was adopted."
                )
            } else if let authenticatedPath {
                let path: String
                let diagnostic: String
                switch authenticatedPath {
                case .direct:
                    path = "direct Host connection"
                    diagnostic = "PAIR-DIRECT-AFTER-VERIFY"
                case .encryptedRelay:
                    path = "encrypted relay connection"
                    diagnostic = "PAIR-RELAY-AFTER-VERIFY"
                }
                state = .failed(
                    title: "Pairing Connection Ended",
                    message: "Harc authenticated the Host, but the \(path) could not continue through claim creation. Keep both Harc apps open and create a fresh Mac client invitation. Diagnostic: \(diagnostic). No device was adopted."
                )
            } else {
                state = .failed(
                    title: "Pairing Couldn’t Start",
                    message: "Harc authenticated a Host connection, but the one-time pairing claim could not be created. Keep the Host pairing window open, create a fresh Mac client invitation, and try again. No device was adopted."
                )
            }
        }
    }

    func review(pairingURI: String) {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        do {
            let nowMS = UInt64(Date().timeIntervalSince1970 * 1_000)
            let ticket = try PairingTicketV1.decodeURI(
                pairingURI,
                atUnixMilliseconds: nowMS
            )
            let route = try HarcDesktopHostRoute(ticket: ticket)
            reviewedPairingURI = pairingURI
            state = .reviewInvitation(
                host: route.host,
                fingerprint: Self.hostFingerprint(ticket.hostAuthorityID),
                expiresAt: Date(
                    timeIntervalSince1970:
                        Double(ticket.expiresAtUnixMilliseconds) / 1_000
                )
            )
        } catch {
            reviewedPairingURI = nil
            let message: String
            if let codecError = error as? HarcProtocolCodecError,
               case .expired = codecError {
                message = "This invitation has expired. Create a new Mac client invitation on the Host and try again."
            } else {
                message = "This invitation is invalid or was created by an unsupported Harc version. Update Harc on both Macs and create a fresh Mac client invitation."
            }
            state = .failed(
                title: "Invitation Can’t Be Used",
                message: message
            )
        }
    }

    func acceptReviewedInvitation() async {
        guard let pairingURI = reviewedPairingURI else {
            state = .unpaired
            return
        }
        reviewedPairingURI = nil
        await begin(pairingURI: pairingURI)
    }

    func declineReviewedInvitation() {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        reviewedPairingURI = nil
        state = .unpaired
    }

    func confirmWordsMatch() async {
        guard let attempt, confirmingAttemptID == nil else { return }
        let attemptID = attempt.id
        let generation = operationGeneration
        confirmingAttemptID = attemptID
        defer {
            if confirmingAttemptID == attemptID {
                confirmingAttemptID = nil
            }
        }
        var active = attempt
        var reconnectFailures = 0
        state = .awaitingHostApproval(
            host: attempt.presentation.hostDisplayName,
            phrase: attempt.presentation.sas.displayedPhrase
        )
        do {
            while true {
                try Task.checkCancellation()
                guard isCurrent(attemptID: attemptID, generation: generation)
                else {
                    throw HarcDesktopClientPairingError.ended("cancelled")
                }
                let now = UInt64(Date().timeIntervalSince1970 * 1_000)
                guard !active.presentation.isExpired(
                    atUnixMilliseconds: now
                )
                else { throw HarcDesktopClientPairingError.ended("expired") }
                let result: HarcPairingClaimResult
                do {
                    result = try await active.client.getPairingStatus()
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    reconnectFailures = 0
                } catch {
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    let reconnectNow = UInt64(
                        Date().timeIntervalSince1970 * 1_000
                    )
                    guard !active.presentation.isExpired(
                        atUnixMilliseconds: reconnectNow
                    )
                    else { throw error }
                    do {
                        let reconnected = try await reconnect(active)
                        guard isCurrent(
                            attemptID: attemptID,
                            generation: generation
                        ) else {
                            await reconnected.connection.shutdownImmediately()
                            return
                        }
                        active = reconnected
                        self.attempt = reconnected
                        reconnectFailures = 0
                    } catch {
                        guard isCurrent(
                            attemptID: attemptID,
                            generation: generation
                        ) else { return }
                        reconnectFailures = min(reconnectFailures + 1, 4)
                        let delayMS = [500, 1_000, 2_000, 5_000][
                            reconnectFailures - 1
                        ]
                        try await Task.sleep(
                            for: .milliseconds(delayMS)
                        )
                    }
                    continue
                }
                switch result {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .approved(let adoption, let remoteRelayRoute):
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    let adoptedRoute = try HarcDesktopHostRoute(
                        host: active.route.host,
                        port: active.route.port,
                        serverHostname: active.route.serverHostname,
                        relay: remoteRelayRoute
                    )
                    let priorRoute = try? HarcDesktopHostRouteStore.load(
                        from: routeURL
                    )
                    try HarcDesktopHostRouteStore.save(
                        adoptedRoute,
                        to: routeURL
                    )
                    do {
                        _ = try store.adoptApprovedForegroundPairing(adoption)
                    } catch {
                        // Route evidence is useful only with the matching
                        // durable adoption. Do not leave an orphaned endpoint
                        // behind when the atomic trust adoption rejects.
                        if let priorRoute {
                            try? HarcDesktopHostRouteStore.save(
                                priorRoute,
                                to: routeURL
                            )
                        } else {
                            try? HarcDesktopHostRouteStore.removeIfPresent(
                                at: routeURL
                            )
                        }
                        throw error
                    }
                    self.attempt = nil
                    state = .paired(
                        host: active.presentation.hostDisplayName
                    )
                    onAdopted()
                    try await active.connection.shutdownGracefully()
                    return
                case .denied:
                    throw HarcDesktopClientPairingError.ended("denied")
                case .expired:
                    throw HarcDesktopClientPairingError.ended("expired")
                case .cancelled:
                    throw HarcDesktopClientPairingError.ended("cancelled")
                }
            }
        } catch {
            await active.connection.shutdownImmediately()
            guard isCurrent(
                attemptID: attemptID,
                generation: generation
            ) else { return }
            self.attempt = nil
            let message: String
            if let pairingError = error as? HarcDesktopClientPairingError {
                message = pairingError.localizedDescription
            } else {
                message = "The pairing claim expired before Harc could reconnect and receive Host approval. Create a fresh invitation and try again."
            }
            state = .failed(
                title: "Pairing Wasn’t Approved",
                message: message
            )
        }
    }

    /// Re-authenticates the original ticket route and transfers the proved
    /// claimant state to a fresh RPC client. A route reconnect can never alter
    /// the Host authority or security words already shown to the user.
    private func reconnect(_ attempt: ActiveAttempt) async throws -> ActiveAttempt {
        let trust = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet:
                attempt.ticket.exactTransportObjectBytes,
            hostAuthorityPublicKey: attempt.ticket.hostAuthorityPublicKey
        )
        let policy = try HarcDesktopHostSessionConnector.capabilityPolicy()
        let expectation = try HarcBootstrapTrustExpectation(
            pairingTicket: attempt.ticket
        )
        let verify: @Sendable (HarcPinnedGRPCConnection) async throws
            -> HarcValidatedHostBootstrapInfo = { candidate in
            let verifier = HarcBootstrapClient(
                rpc: candidate,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            return try await verifier.getHostInfo(expectation: expectation)
        }
        let verified: HarcDesktopVerifiedHostConnection<
            HarcValidatedHostBootstrapInfo
        >
        let reconnectedRoute: HarcDesktopHostRoute
        do {
            verified = try await HarcDesktopHostRouteConnector.openVerified(
                route: attempt.route,
                trust: trust,
                verify: verify
            )
            reconnectedRoute = attempt.route
        } catch let originalError {
            // A short-lived pairing ticket still binds identity, not an IP
            // address. If DHCP or a dock changes during Host approval, try
            // Bonjour candidates and authenticate each one against the exact
            // original ticket before resuming the proved claim.
            var repairedConnection: HarcDesktopVerifiedHostConnection<
                HarcValidatedHostBootstrapInfo
            >?
            var repairedRoute: HarcDesktopHostRoute?
            for candidate in await HarcMobileBonjourHostRouteResolver.discover() {
                guard candidate.host != attempt.route.host
                        || candidate.port != attempt.route.port else { continue }
                let directCandidate = try HarcDesktopHostRoute(
                    host: candidate.host,
                    port: candidate.port,
                    serverHostname: attempt.route.serverHostname,
                    relay: nil
                )
                do {
                    repairedConnection = try await
                        HarcDesktopHostRouteConnector.openVerified(
                            route: directCandidate,
                            trust: trust,
                            verify: verify
                        )
                    repairedRoute = try HarcDesktopHostRoute(
                        host: candidate.host,
                        port: candidate.port,
                        serverHostname: attempt.route.serverHostname,
                        relay: attempt.route.relay
                    )
                    break
                } catch {
                    continue
                }
            }
            guard let repairedConnection, let repairedRoute else {
                throw originalError
            }
            verified = repairedConnection
            reconnectedRoute = repairedRoute
        }
        do {
            let client = try await attempt.client.resumingPairing(
                on: verified.connection
            )
            await attempt.connection.shutdownImmediately()
            return ActiveAttempt(
                id: attempt.id,
                client: client,
                connection: verified.connection,
                ticket: attempt.ticket,
                route: reconnectedRoute,
                presentation: attempt.presentation
            )
        } catch {
            await verified.connection.shutdownImmediately()
            throw error
        }
    }

    func wordsDoNotMatch() async {
        guard let attempt else {
            state = .unpaired
            return
        }
        operationGeneration &+= 1
        self.attempt = nil
        state = .failed(
            title: "Security Words Didn’t Match",
            message: "This Host was not adopted. Do not continue with this invitation; create a new Mac client invitation on the intended Host."
        )
        await attempt.client.abandonLocalPairingState()
        await attempt.connection.shutdownImmediately()
    }

    func reset() {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        reviewedPairingURI = nil
        state = .unpaired
    }

    func forgetHost() {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        reviewedPairingURI = nil
        do {
            _ = try store.forgetActiveHost()
            try HarcDesktopHostRouteStore.removeIfPresent(at: routeURL)
            onForgetting()
            state = .unpaired
        } catch {
            state = .failed(
                title: "Host Couldn’t Be Forgotten",
                message: "Harc could not finish removing this Host from the Mac. No recordings were deleted. Try again before pairing with a different Host."
            )
        }
    }

    func cancel() {
        operationGeneration &+= 1
        reviewedPairingURI = nil
        guard let attempt else {
            state = Self.stateAfterPassiveClose(state)
            return
        }
        self.attempt = nil
        Task {
            await attempt.client.abandonLocalPairingState()
            await attempt.connection.shutdownImmediately()
        }
        state = .unpaired
    }

    private func isCurrent(attemptID: UUID, generation: UInt64) -> Bool {
        Self.operationIsCurrent(
            currentGeneration: operationGeneration,
            expectedGeneration: generation,
            currentAttemptID: attempt?.id,
            expectedAttemptID: attemptID
        )
    }

    static func operationIsCurrent(
        currentGeneration: UInt64,
        expectedGeneration: UInt64,
        currentAttemptID: UUID?,
        expectedAttemptID: UUID
    ) -> Bool {
        currentGeneration == expectedGeneration
            && currentAttemptID == expectedAttemptID
    }

    static func stateAfterPassiveClose(_ current: State) -> State {
        if case .paired = current { return current }
        return .unpaired
    }

    static func requestedScopes() -> [AuthorizationScope] {
        var scopes = ScopePolicy.minimalScopes(for: .macClient)
        scopes.append(contentsOf: [
            .libraryMetadataRead,
            .libraryTranscriptRead,
            .libraryAudioRead,
            .libraryMetadataWrite,
            .speakerIdentityRead,
            .speakerObservationWrite,
            .speakerAssignmentWrite,
        ])
        return Array(Set(scopes)).sorted()
    }

    private static func hostFingerprint(
        _ hostAuthorityID: HostAuthorityID
    ) -> String {
        let value = hostAuthorityID.description.uppercased()
        return stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(
                start,
                offsetBy: min(4, value.count - offset)
            )
            return String(value[start ..< end])
        }.joined(separator: " ")
    }
}

private struct HarcDesktopClientPairingView: View {
    @ObservedObject var model: HarcDesktopClientPairingCoordinator
    @State private var showingScanner = false
    @State private var cameras = [HarcDesktopPairingCamera]()
    @State private var selectedCameraID = ""
    @State private var scannerFailure: String?
    @State private var showingInvitationImporter = false
    @State private var showingForgetConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "macmini.and.macbook")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
            Text("Pair with your Harc Host")
                .font(.title2.weight(.semibold))
            Text(
                "On the Host, choose Pair a Device and select Mac client. Open its short-lived pairing invite, scan its code, or paste its link, then compare the four security words on both Macs."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 560)
        .frame(minHeight: 540)
        .fileImporter(
            isPresented: $showingInvitationImporter,
            allowedContentTypes: [.harcPairingInvitation],
            allowsMultipleSelection: false
        ) { result in
            importPairingInvitation(result)
        }
        .confirmationDialog(
            "Forget this Host?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Host", role: .destructive) {
                showingScanner = false
                model.forgetHost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops this Mac from connecting automatically. Local recordings and queued transfers stay on this Mac. The Host will still list this installation until it is revoked there.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .unpaired:
            if showingScanner {
                VStack(spacing: 12) {
                    if cameras.count > 1 {
                        Picker("Camera", selection: $selectedCameraID) {
                            ForEach(cameras) { camera in
                                Text(camera.name).tag(camera.id)
                            }
                        }
                    }
                    HarcDesktopPairingScannerView(
                        cameraID: selectedCameraID,
                        onCode: { code in
                            showingScanner = false
                            scannerFailure = nil
                            Task { await model.begin(pairingURI: code) }
                        },
                        onReady: {
                            scannerFailure = nil
                        },
                        onFailure: { message in
                            scannerFailure = message
                        }
                    )
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    if let scannerFailure {
                        Label(scannerFailure, systemImage: "camera.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    Button("Cancel Scan") { showingScanner = false }
                }
            } else {
                VStack(spacing: 12) {
                    Text(
                        "Move a saved invite between Macs without a shared clipboard. The Host must be online; Harc connects directly when possible and uses its encrypted relay when needed."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    HStack {
                        Button("Open Pairing Invite…") {
                            showingInvitationImporter = true
                        }
                            .buttonStyle(.borderedProminent)
                        Button("Paste Pairing Link") { pastePairingLink() }
                    }
                    Button("Scan Host Code") { startScanning() }
                    if let scannerFailure {
                        Label(scannerFailure, systemImage: "camera.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        case .reviewInvitation(let host, let fingerprint, let expiresAt):
            VStack(spacing: 14) {
                Label(
                    "Review Pairing Invitation",
                    systemImage: "doc.badge.gearshape"
                )
                .font(.headline)
                Text(host)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Host authority fingerprint")
                        .font(.caption.weight(.semibold))
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                Text("Expires \(expiresAt, style: .relative). Connecting creates a pending claim only; this Host must still show matching security words and approve this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) {
                        model.declineReviewedInvitation()
                    }
                    Button("Connect to This Host") {
                        Task { await model.acceptReviewedInvitation() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .connecting:
            VStack(spacing: 10) {
                ProgressView("Opening a secure Host connection…")
                Text("Harc tries the direct route first, then the encrypted relay when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .compareWords(let host, let phrase, let expiresAt):
            VStack(spacing: 14) {
                Text("Compare with \(host)").font(.headline)
                Text(phrase)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Words Do Not Match", role: .destructive) {
                        Task { await model.wordsDoNotMatch() }
                    }
                    Button("Words Match") {
                        Task { await model.confirmWordsMatch() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .awaitingHostApproval(let host, let phrase):
            VStack(spacing: 12) {
                ProgressView("Waiting for approval on \(host)…")
                Text(phrase)
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
        case .paired(let host):
            VStack(spacing: 14) {
                result(
                    symbol: "checkmark.shield.fill",
                    color: .green,
                    title: "Paired with \(host)",
                    detail: "New Client recordings can now resume secure, compressed transfer. Your previous local library remains On This Mac."
                )
                Button("Forget This Host…", role: .destructive) {
                    showingForgetConfirmation = true
                }
            }
        case .failed(let title, let message):
            VStack(spacing: 14) {
                result(
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: title,
                    detail: message
                )
                Text("No device was adopted. Use a newly generated invitation for the correct device type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Open New Invite…") {
                        showingScanner = false
                        scannerFailure = nil
                        model.reset()
                        showingInvitationImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Paste New Link") {
                        showingScanner = false
                        scannerFailure = nil
                        model.reset()
                        pastePairingLink()
                    }
                }
                Button("Back") {
                    showingScanner = false
                    scannerFailure = nil
                    model.reset()
                }
                .buttonStyle(.link)
            }
        }
    }

    private func startScanning() {
        let discovered = HarcDesktopPairingCameraDiscovery.availableCameras()
        guard let first = discovered.first else {
            scannerFailure = "No camera is available. Connect a camera or make an iPhone available as Continuity Camera."
            return
        }
        cameras = discovered
        if !discovered.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = first.id
        }
        scannerFailure = nil
        showingScanner = true
    }

    private func pastePairingLink() {
        let rawValue = NSPasteboard.general.string(forType: .string)
        guard rawValue != nil else {
            scannerFailure = "The clipboard does not contain a Harc pairing link."
            return
        }
        guard let value = HarcDesktopPairingCodeFilter.pastedCandidate(
            rawValue
        ) else {
            scannerFailure = "The clipboard does not contain a valid Harc pairing link. Create a fresh link on the Host and copy it again."
            return
        }
        showingScanner = false
        scannerFailure = nil
        model.review(pairingURI: value)
    }

    private func importPairingInvitation(
        _ result: Result<[URL], any Error>
    ) {
        do {
            guard let url = try result.get().first else {
                throw HarcPairingInvitationDocumentError.unreadableFile
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let pairingURI = try HarcPairingInvitationDocument.load(from: url)
            showingScanner = false
            scannerFailure = nil
            model.review(pairingURI: pairingURI)
        } catch {
            scannerFailure = error.localizedDescription
        }
    }

    private func result(
        symbol: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private enum HarcDesktopClientPairingError: LocalizedError {
    case ended(String)

    var errorDescription: String? {
        switch self {
        case .ended(let state):
            switch state {
            case "denied":
                "The Host denied this Mac. No device was adopted. Create a fresh invitation if you want to try again."
            case "expired":
                "The Host invitation expired before approval. Create a fresh Mac client invitation and try again."
            case "cancelled":
                "The Host cancelled this pairing invitation. Create a fresh Mac client invitation to try again."
            default:
                "Pairing ended without Host approval. Create a fresh invitation and try again."
            }
        }
    }
}
