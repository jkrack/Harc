import AppKit
import Combine
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer
import SwiftUI

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
        case connecting
        case compareWords(host: String, phrase: String, expiresAt: Date)
        case awaitingHostApproval(host: String, phrase: String)
        case paired(host: String)
        case failed(String)
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
        guard HarcDesktopPairingCodeFilter.accepts(pairingURI) else {
            state = .failed("Scan a fresh Harc pairing code shown by your Host.")
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
            let opened = try await HarcPinnedGRPCConnection.connect(
                host: route.host,
                port: Int(route.port),
                serverHostname: route.serverHostname,
                trustCoordinator: trust
            )
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
            state = .failed(error.localizedDescription)
        }
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
                case .approved(let adoption):
                    try HarcDesktopHostRouteStore.save(
                        attempt.route,
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
            state = .failed(error.localizedDescription)
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
            "Security words did not match. This Host was not adopted. Create a new pairing code."
        )
    }

    func reset() {
        guard attempt == nil else { return }
        state = .unpaired
    }

    func cancel() {
        guard let attempt else { return }
        self.attempt = nil
        Task {
            await attempt.client.abandonLocalPairingState()
            await attempt.connection.shutdownImmediately()
        }
        state = .unpaired
    }

    private static func requestedScopes() -> [AuthorizationScope] {
        var scopes = ScopePolicy.minimalScopes(for: .macClient)
        scopes.append(contentsOf: [
            .libraryMetadataRead,
            .libraryTranscriptRead,
            .libraryAudioRead,
            .libraryMetadataWrite,
        ])
        return Array(Set(scopes)).sorted()
    }
}

private struct HarcDesktopClientPairingView: View {
    @ObservedObject var model: HarcDesktopClientPairingCoordinator
    @State private var showingScanner = false
    @State private var cameras = [HarcDesktopPairingCamera]()
    @State private var selectedCameraID = ""
    @State private var scannerFailure: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "macmini.and.macbook")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
            Text("Pair with your Harc Host")
                .font(.title2.weight(.semibold))
            Text(
                "On the Host, choose Pair a Device and select Mac client. Scan its short-lived code, then compare the four security words on both Macs."
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
                        "Use this Mac's built-in, external, or Continuity Camera. The pairing secret never enters the clipboard or a cloud service."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Button("Scan Host Code") { startScanning() }
                        .buttonStyle(.borderedProminent)
                    if let scannerFailure {
                        Label(scannerFailure, systemImage: "camera.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        case .connecting:
            ProgressView("Opening a pinned local connection…")
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
        case .failed(let message):
            VStack(spacing: 14) {
                result(
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "Pairing unavailable",
                    detail: message
                )
                Button("Try Again") {
                    showingScanner = false
                    scannerFailure = nil
                    model.reset()
                }
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
            "Pairing ended without approval: \(state)."
        }
    }
}
