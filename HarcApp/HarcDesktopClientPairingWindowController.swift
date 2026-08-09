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
        let client: HarcBootstrapClient
        let connection: HarcPinnedGRPCConnection
        let route: HarcDesktopHostRoute
        let presentation: HarcPairingClaimPresentation
    }

    @Published private(set) var state: State

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let routeURL: URL
    private let onAdopted: @MainActor () -> Void
    private var attempt: ActiveAttempt?
    private var reviewedPairingURI: String?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL,
        hasActiveAdoption: Bool,
        onAdopted: @escaping @MainActor () -> Void = {}
    ) {
        self.identity = identity
        self.store = store
        self.routeURL = routeURL
        self.onAdopted = onAdopted
        state = hasActiveAdoption ? .paired(host: "Adopted Host") : .unpaired
    }

    func begin(pairingURI: String) async {
        guard attempt == nil else { return }
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
            let opened: HarcPinnedGRPCConnection
            do {
                opened = try await HarcPinnedGRPCConnection.connect(
                    host: route.host,
                    port: Int(route.port),
                    serverHostname: route.serverHostname,
                    trustCoordinator: trust
                )
            } catch {
                guard let relay = route.relay else { throw error }
                let tunnel = try await HarcRemoteRelayClientTunnel.open(
                    route: relay
                )
                do {
                    opened = try await HarcPinnedGRPCConnection.connect(
                        host: tunnel.localHost,
                        port: Int(tunnel.localPort),
                        serverHostname: route.serverHostname,
                        trustCoordinator: trust,
                        transportLifetime: tunnel
                    )
                } catch {
                    await tunnel.shutdown()
                    throw error
                }
            }
            connection = opened
            let client = HarcBootstrapClient(
                rpc: opened,
                capabilityPolicy:
                    try HarcDesktopHostSessionConnector.capabilityPolicy(),
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let presentation = try await client.beginPairing(
                ticket: ticket,
                deviceSigner: identity,
                requestedScopes: Self.requestedScopes(),
                deviceLabel: ProcessInfo.processInfo.hostName
            )
            attempt = ActiveAttempt(
                client: client,
                connection: opened,
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
            if let error = error as? HarcBootstrapClientError {
                state = .failed(
                    title: "Pairing Request Rejected",
                    message: error.localizedDescription
                )
            } else {
                state = .failed(
                    title: "Host Couldn’t Be Reached",
                    message: "Harc couldn’t reach the Host directly or through the encrypted relay. Make sure the Host is open, online, and still showing the pairing screen, then create a fresh Mac client invitation."
                )
            }
        }
    }

    func review(pairingURI: String) {
        guard attempt == nil else { return }
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
        reviewedPairingURI = nil
        state = .unpaired
    }

    func confirmWordsMatch() async {
        guard let attempt else { return }
        state = .awaitingHostApproval(
            host: attempt.presentation.hostDisplayName,
            phrase: attempt.presentation.sas.displayedPhrase
        )
        do {
            while true {
                try Task.checkCancellation()
                switch try await attempt.client.getPairingStatus() {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .approved(let adoption, let remoteRelayRoute):
                    let adoptedRoute = try HarcDesktopHostRoute(
                        host: attempt.route.host,
                        port: attempt.route.port,
                        serverHostname: attempt.route.serverHostname,
                        relay: remoteRelayRoute
                    )
                    try HarcDesktopHostRouteStore.save(
                        adoptedRoute,
                        to: routeURL
                    )
                    _ = try store.adopt(adoption)
                    try await attempt.connection.shutdownGracefully()
                    self.attempt = nil
                    state = .paired(
                        host: attempt.presentation.hostDisplayName
                    )
                    onAdopted()
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
            await attempt.connection.shutdownImmediately()
            self.attempt = nil
            let message: String
            if let pairingError = error as? HarcDesktopClientPairingError {
                message = pairingError.localizedDescription
            } else {
                message = "The secure connection ended before the Host approved this Mac. Make sure the Host is online and still showing the same security words, then create a fresh invitation."
            }
            state = .failed(
                title: "Pairing Wasn’t Approved",
                message: message
            )
        }
    }

    func wordsDoNotMatch() async {
        guard let attempt else {
            state = .unpaired
            return
        }
        await attempt.client.abandonLocalPairingState()
        await attempt.connection.shutdownImmediately()
        self.attempt = nil
        state = .failed(
            title: "Security Words Didn’t Match",
            message: "This Host was not adopted. Do not continue with this invitation; create a new Mac client invitation on the intended Host."
        )
    }

    func reset() {
        guard attempt == nil else { return }
        reviewedPairingURI = nil
        state = .unpaired
    }

    func cancel() {
        reviewedPairingURI = nil
        guard let attempt else {
            state = .unpaired
            return
        }
        self.attempt = nil
        Task {
            await attempt.client.abandonLocalPairingState()
            await attempt.connection.shutdownImmediately()
        }
        state = .unpaired
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
                Button("Pair with a Different Host") {
                    showingScanner = false
                    model.reset()
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
