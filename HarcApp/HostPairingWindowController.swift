import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import HarcHost
import HarcHostTransport
import HarcIdentity
import SwiftUI

@MainActor
final class HostPairingWindowController: NSWindowController, NSWindowDelegate {
    private let model: HostPairingViewModel

    init(runtime: HarcResidentHostRuntimeV1) {
        model = HostPairingViewModel(runtime: runtime)
        let root = HostPairingView(model: model)
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: root)
        )
        window.title = "Pair a Device"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 650))
        window.minSize = NSSize(width: 480, height: 600)
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
private final class HostPairingViewModel: ObservableObject {
    enum Phase {
        case idle
        case issuing
        case ticket(HarcForegroundPairingTicketV1)
        case claim(HarcForegroundPairingTicketV1, HostPendingPairingClaim)
        case approved(String)
        case denied
        case failed(String)
    }

    @Published var selectedKind: AdoptedClientKind = .mobile
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var approvedScopes = Set<AuthorizationScope>()

    private let runtime: HarcResidentHostRuntimeV1
    private var task: Task<Void, Never>?

    init(runtime: HarcResidentHostRuntimeV1) {
        self.runtime = runtime
    }

    func begin() {
        guard task == nil else { return }
        phase = .issuing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await runtime.issuePairingTicket(
                    for: selectedKind
                )
                try Task.checkCancellation()
                phase = .ticket(ticket)
                try await poll(ticket: ticket)
            } catch is CancellationError {
                // Closing the foreground window intentionally cancels the
                // memory-only secret and its durable reservation.
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func restart() {
        task?.cancel()
        task = nil
        Task { try? await runtime.cancelPairingTicket() }
        phase = .idle
        begin()
    }

    func approve() {
        guard case .claim(_, let claim) = phase else { return }
        let grantedScopes = approvedScopes.sorted()
        guard !grantedScopes.isEmpty else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await runtime.approvePairingClaim(
                    claim.claimID,
                    grantedScopes: grantedScopes
                )
                phase = .approved(claim.deviceLabel)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func setScope(_ scope: AuthorizationScope, enabled: Bool) {
        guard case .claim(_, let claim) = phase,
              claim.requestedScopes.contains(scope) else { return }
        if enabled {
            approvedScopes.insert(scope)
        } else {
            approvedScopes.remove(scope)
        }
    }

    func deny() {
        guard case .claim(_, let claim) = phase else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.denyPairingClaim(claim.claimID)
                phase = .denied
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func copyPairingLink() {
        guard let ticket = currentTicket else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ticket.pairingURI, forType: .string)
    }

    func cancel() {
        task?.cancel()
        task = nil
        Task { try? await runtime.cancelPairingTicket() }
    }

    var currentTicket: HarcForegroundPairingTicketV1? {
        switch phase {
        case .ticket(let ticket), .claim(let ticket, _): ticket
        default: nil
        }
    }

    private func poll(ticket: HarcForegroundPairingTicketV1) async throws {
        while Date() < ticket.expiresAt {
            try Task.checkCancellation()
            if let claim = try await runtime.pendingPairingClaim(
                forTicketID: ticket.ticketID
            ) {
                approvedScopes = Set(claim.requestedScopes)
                phase = .claim(ticket, claim)
                return
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw HostPairingPresentationError.ticketExpired
    }
}

private enum HostPairingPresentationError: LocalizedError {
    case ticketExpired

    var errorDescription: String? {
        "The pairing code expired. Create a new code and try again."
    }
}

private struct HostPairingView: View {
    @ObservedObject var model: HostPairingViewModel

    var body: some View {
        VStack(spacing: 20) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520)
        .frame(minHeight: 620)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
            Text("Pair a Device")
                .font(.title2.weight(.semibold))
            Text("The device will trust this Mac as its Harc host. Audio and library traffic stay on your authenticated local connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                Picker("Device type", selection: $model.selectedKind) {
                    Text("iPhone").tag(AdoptedClientKind.mobile)
                    Text("Mac client").tag(AdoptedClientKind.macClient)
                }
                .pickerStyle(.segmented)
                Button("Create Pairing Code") { model.begin() }
                    .buttonStyle(.borderedProminent)
            }
        case .issuing:
            ProgressView("Creating a short-lived pairing code…")
        case .ticket(let ticket):
            ticketContent(ticket)
        case .claim(_, let claim):
            claimContent(claim)
        case .approved(let label):
            resultContent(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: "Paired",
                detail: "\(label) can now connect with its approved device identity."
            )
        case .denied:
            resultContent(
                symbol: "xmark.circle.fill",
                color: .secondary,
                title: "Pairing denied",
                detail: "No device grant was issued."
            )
        case .failed(let message):
            resultContent(
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Pairing unavailable",
                detail: message
            )
        }
    }

    private func ticketContent(
        _ ticket: HarcForegroundPairingTicketV1
    ) -> some View {
        VStack(spacing: 14) {
            if let image = HostPairingQRCode.image(for: ticket.pairingURI) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                    .accessibilityLabel("Harc pairing QR code")
            }
            Text("Scan this code in Harc. It expires in two minutes and can be used only once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Copy Pairing Link") { model.copyPairingLink() }
            ProgressView("Waiting for the device…")
                .controlSize(.small)
        }
    }

    private func claimContent(_ claim: HostPendingPairingClaim) -> some View {
        ScrollView {
        VStack(spacing: 18) {
            Text(claim.requiresTransportTrustRepair
                 ? "Repair transport trust for \(claim.deviceLabel)?"
                 : "Approve \(claim.deviceLabel)?")
                .font(.headline)
            Text("Confirm these four words match exactly on the device:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(claim.sasWords.joined(separator: "  "))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Text("Approved access")
                    .font(.subheadline.weight(.semibold))
                ForEach(claim.requestedScopes, id: \.self) { scope in
                    Toggle(
                        isOn: Binding(
                            get: { model.approvedScopes.contains(scope) },
                            set: { model.setScope(scope, enabled: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scopeTitle(scope))
                            Text(scope.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if claim.requestedScopes.contains(where: \.isLibraryScope) {
                    Label(
                        "Library access requires your Mac password or Touch ID.",
                        systemImage: "touchid"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Deny", role: .destructive) { model.deny() }
                Spacer()
                Button("Words Match — Approve") { model.approve() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.approvedScopes.isEmpty)
            }
        }
        }
    }

    private func scopeTitle(_ scope: AuthorizationScope) -> String {
        switch scope {
        case .recordingUploadOwn: "Upload this device's recordings"
        case .recordingReadOwn: "Read this device's recording status"
        case .libraryMetadataRead: "Browse Library metadata"
        case .libraryTranscriptRead: "Read transcripts and summaries"
        case .libraryAudioRead: "Play Library audio"
        case .libraryMetadataWrite: "Edit Library metadata"
        case .processingSubmitOwn: "Submit local processing artifacts"
        }
    }

    private func resultContent(
        symbol: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(color)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Another Pairing Code") { model.restart() }
        }
    }
}

private enum HostPairingQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ), let cgImage = CIContext().createCGImage(
            output,
            from: output.extent
        ) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
