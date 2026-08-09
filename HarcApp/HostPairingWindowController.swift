import AppKit
import Combine
import CoreTransferable
import CoreImage
import CoreImage.CIFilterBuiltins
import HarcDomain
import HarcHost
import HarcHostTransport
import HarcIdentity
import HarcProtocol
import SwiftUI
import UniformTypeIdentifiers

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
        case approved(HostPairedDevicePresentation)
        case denied
        case failed(String)
    }

    // Pairing permissions differ materially between iPhone and Mac clients.
    // Require an explicit choice instead of silently issuing the wrong ticket.
    @Published var selectedKind: AdoptedClientKind?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var approvedScopes = Set<AuthorizationScope>()
    @Published private(set) var pairedDevices = [HostPairedDeviceSummary]()
    @Published private(set) var pairingLinkCopied = false
    @Published private(set) var pairingInviteExportStatus: String?
    @Published var pendingRevocation: HostPairedDeviceSummary?
    @Published private(set) var revokingDeviceID: DeviceID?
    @Published private(set) var deviceManagementError: String?

    private let runtime: HarcResidentHostRuntimeV1
    private var task: Task<Void, Never>?
    private var deviceManagementTask: Task<Void, Never>?

    init(runtime: HarcResidentHostRuntimeV1) {
        self.runtime = runtime
        Task { [weak self] in
            await self?.refreshPairedDevices()
        }
    }

    func begin() {
        guard task == nil, let selectedKind else { return }
        phase = .issuing
        task = Task { [weak self] in
            await self?.runPairingFlow(
                for: selectedKind,
                cancelExistingTicket: false
            )
        }
    }

    func restart() {
        guard let selectedKind else { return }
        let previousTask = task
        previousTask?.cancel()
        pairingLinkCopied = false
        pairingInviteExportStatus = nil
        phase = .issuing
        task = Task { [weak self] in
            await previousTask?.value
            await self?.runPairingFlow(
                for: selectedKind,
                cancelExistingTicket: true
            )
        }
    }

    func changeDeviceType() {
        let previousTask = task
        previousTask?.cancel()
        pairingLinkCopied = false
        pairingInviteExportStatus = nil
        phase = .issuing
        task = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            try? await runtime.cancelPairingTicket()
            selectedKind = nil
            phase = .idle
            task = nil
        }
    }

    func approve() {
        guard case .claim(_, let claim) = phase else { return }
        let grantedScopes = approvedScopes.sorted()
        guard !grantedScopes.isEmpty else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let issued = try await runtime.approvePairingClaim(
                    claim.claimID,
                    grantedScopes: grantedScopes
                )
                phase = .approved(
                    HostPairedDevicePresentation(
                        label: claim.deviceLabel,
                        clientKind: claim.clientKind,
                        deviceID: issued.claims.deviceID,
                        scopes: issued.claims.scopes,
                        pairedAt: issued.claims.issuedAt
                    )
                )
                await refreshPairedDevices()
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

    func copyPairingLink(_ ticket: HarcForegroundPairingTicketV1) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pairingLinkCopied = pasteboard.setString(
            ticket.pairingURI,
            forType: .string
        )
    }

    func savePairingInvite(_ ticket: HarcForegroundPairingTicketV1) {
        let panel = NSSavePanel()
        panel.title = "Save Pairing Invite"
        panel.prompt = "Save Invite"
        panel.nameFieldStringValue =
            "Harc Pairing Invite.\(PairingInvitationFileV1.filenameExtension)"
        panel.allowedContentTypes = [.harcPairingInvitation]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HarcPairingInvitationDocument.save(
                pairingURI: ticket.pairingURI,
                to: url
            )
            pairingInviteExportStatus =
                "Invite saved. It remains usable only until the countdown ends."
        } catch {
            pairingInviteExportStatus = error.localizedDescription
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

    func cancel() {
        task?.cancel()
        deviceManagementTask?.cancel()
        task = nil
        deviceManagementTask = nil
        Task { try? await runtime.cancelPairingTicket() }
    }

    func requestRevocation(_ device: HostPairedDeviceSummary) {
        pendingRevocation = device
        deviceManagementError = nil
    }

    func confirmRevocation() {
        guard let device = pendingRevocation,
              deviceManagementTask == nil else { return }
        pendingRevocation = nil
        revokingDeviceID = device.deviceID
        deviceManagementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.revokePairedDevice(device.deviceID)
                deviceManagementError = nil
            } catch is CancellationError {
                // Window dismissal intentionally cancels UI management work.
            } catch {
                deviceManagementError = error.localizedDescription
            }
            await refreshPairedDevices()
            revokingDeviceID = nil
            deviceManagementTask = nil
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

    private func runPairingFlow(
        for selectedKind: AdoptedClientKind,
        cancelExistingTicket: Bool
    ) async {
        do {
            if cancelExistingTicket {
                try await runtime.cancelPairingTicket()
                try Task.checkCancellation()
            }
            let ticket = try await runtime.issuePairingTicket(
                for: selectedKind
            )
            try Task.checkCancellation()
            pairingLinkCopied = false
            pairingInviteExportStatus = nil
            phase = .ticket(ticket)
            try await poll(ticket: ticket)
        } catch is CancellationError {
            // Closing the foreground window intentionally cancels the
            // memory-only secret and its durable reservation.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func refreshPairedDevices() async {
        do {
            pairedDevices = try await runtime.pairedDevices()
        } catch {
            // Pairing remains available even if the management projection
            // cannot be loaded. Approval errors continue to surface normally.
        }
    }
}

private struct HostPairedDevicePresentation: Equatable {
    let label: String
    let clientKind: AdoptedClientKind
    let deviceID: DeviceID
    let scopes: [AuthorizationScope]
    let pairedAt: Date
}

private enum HostPairingPresentationError: LocalizedError {
    case ticketExpired

    var errorDescription: String? {
        "The pairing code expired. Create a new code and try again."
    }
}

private struct HarcPairingInvitationShareItem: Transferable, Sendable {
    let pairingURI: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: .harcPairingInvitation
        ) { item in
            let file = try HarcPairingInvitationDocument
                .makeTemporaryShareFile(pairingURI: item.pairingURI)
            return SentTransferredFile(
                file,
                allowAccessingOriginalFile: false
            )
        }
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
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(
                get: { model.pendingRevocation != nil },
                set: { if !$0 { model.pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke Device", role: .destructive) {
                model.confirmRevocation()
            }
            Button("Cancel", role: .cancel) {
                model.pendingRevocation = nil
            }
        } message: {
            Text("This immediately invalidates the Harc grant and removes its remote relay access. Pair the installation again to restore access.")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
            Text("Pair a Device")
                .font(.title2.weight(.semibold))
            Text("The device will trust this Mac as its Harc Host. Harc uses pinned end-to-end encryption over a direct connection or its content-blind relay.")
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
                Text("Which device are you pairing?")
                    .font(.headline)
                Text("The invitation and permissions are specific to the selected device type.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Picker("Device type", selection: $model.selectedKind) {
                    Text("iPhone").tag(AdoptedClientKind.mobile as AdoptedClientKind?)
                    Text("Mac client").tag(AdoptedClientKind.macClient as AdoptedClientKind?)
                }
                .pickerStyle(.segmented)
                Button {
                    model.begin()
                } label: {
                    Text(createInvitationButtonTitle)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedKind == nil)
                pairedDevicesSection
            }
        case .issuing:
            ProgressView("Creating a short-lived pairing code…")
        case .ticket(let ticket):
            ticketContent(ticket)
        case .claim(_, let claim):
            claimContent(claim)
        case .approved(let device):
            pairedResultContent(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: "Paired",
                device: device
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

    private var createInvitationButtonTitle: String {
        switch model.selectedKind {
        case .macClient: "Create Mac Invitation"
        case .mobile: "Create iPhone Invitation"
        case nil: "Select a Device Type"
        }
    }

    private func ticketContent(
        _ ticket: HarcForegroundPairingTicketV1
    ) -> some View {
        VStack(spacing: 14) {
            Label("Pairing code created", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Label(
                ticket.clientKind == .macClient
                    ? "Mac client invitation"
                    : "iPhone invitation",
                systemImage: ticket.clientKind == .macClient
                    ? "laptopcomputer"
                    : "iphone"
            )
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12), in: Capsule())
            if let image = HostPairingQRCode.image(for: ticket.pairingURI) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                    .accessibilityLabel("Harc pairing QR code")
            }
            Text(ticket.clientKind == .macClient
                 ? "On the Mac client, choose Pair with Host, then open, scan, or paste this invitation. It can be used only once."
                 : "On the iPhone, open Harc and scan this invitation. It can be used only once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(
                    0,
                    Int(ticket.expiresAt.timeIntervalSince(context.date).rounded(.up))
                )
                Text("Expires in \(seconds) second\(seconds == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView("Waiting for the Client to open this invitation…")
                .controlSize(.small)
            HStack(spacing: 14) {
                Button {
                    model.copyPairingLink(ticket)
                } label: {
                    Label(
                        model.pairingLinkCopied
                            ? "Pairing Link Copied"
                            : "Copy Pairing Link",
                        systemImage: model.pairingLinkCopied
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                ShareLink(
                    item: HarcPairingInvitationShareItem(
                        pairingURI: ticket.pairingURI
                    ),
                    preview: SharePreview("Harc Pairing Invite")
                ) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                }
                Button {
                    model.savePairingInvite(ticket)
                } label: {
                    Label("Save Invite", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.link)
            HStack(spacing: 16) {
                Button("Create Another \(ticket.clientKind == .macClient ? "Mac" : "iPhone") Code") {
                    model.restart()
                }
                Button("Change Device Type") {
                    model.changeDeviceType()
                }
            }
            .buttonStyle(.link)
            if let status = model.pairingInviteExportStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("The invitation contains a temporary pairing secret. Save or Share explicitly exports it outside Harc's adopted-host trust boundary. Use a channel you trust, keep this Host online, and compare all four security words before approval.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func claimContent(_ claim: HostPendingPairingClaim) -> some View {
        ScrollView {
        VStack(spacing: 18) {
            Text(claim.requiresTransportTrustRepair
                 ? "Repair transport trust for \(claim.deviceLabel)?"
                 : "Approve \(claim.deviceLabel)?")
                .font(.headline)
            deviceIdentityCard(
                label: claim.deviceLabel,
                clientKind: claim.clientKind,
                deviceID: claim.deviceID,
                status: nil,
                pairedAt: nil,
                lastConnectedAt: nil,
                scopes: claim.requestedScopes
            )
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
        case .speakerIdentityRead: "Download speaker recognition profiles"
        case .speakerObservationWrite: "Contribute local speaker observations"
        case .speakerAssignmentWrite: "Confirm speaker identities"
        }
    }

    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Paired Devices")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.pairedDevices.isEmpty {
                Text("No paired device identities yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.pairedDevices, id: \.deviceID) { device in
                            deviceIdentityCard(
                                label: device.label,
                                clientKind: device.clientKind,
                                deviceID: device.deviceID,
                                status: device.status,
                                pairedAt: device.pairedAt,
                                lastConnectedAt: device.lastConnectedAt,
                                scopes: device.scopes,
                                actionTitle: device.status == .active
                                    ? "Revoke…"
                                    : "Retry Remote Revocation",
                                actionDisabled:
                                    model.revokingDeviceID == device.deviceID,
                                action: {
                                    model.requestRevocation(device)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            if let error = model.deviceManagementError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func pairedResultContent(
        symbol: String,
        color: Color,
        title: String,
        device: HostPairedDevicePresentation
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(color)
            Text(title).font(.headline)
            deviceIdentityCard(
                label: device.label,
                clientKind: device.clientKind,
                deviceID: device.deviceID,
                status: .active,
                pairedAt: device.pairedAt,
                lastConnectedAt: nil,
                scopes: device.scopes
            )
            Text("This exact installation can now connect with the approved access shown above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Another Pairing Code") { model.restart() }
        }
    }

    private func deviceIdentityCard(
        label: String,
        clientKind: AdoptedClientKind?,
        deviceID: DeviceID,
        status: DeviceRegistryStatus?,
        pairedAt: Date?,
        lastConnectedAt: Date?,
        scopes: [AuthorizationScope],
        actionTitle: String? = nil,
        actionDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label, systemImage: deviceSymbol(clientKind))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let status {
                    Text(status == .active ? "Active" : "Revoked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            status == .active ? Color.green : Color.secondary
                        )
                }
            }
            Text(clientKindTitle(clientKind))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Device fingerprint")
                .font(.caption.weight(.semibold))
            Text(deviceFingerprint(deviceID))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let pairedAt {
                Text("Paired \(pairedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastConnectedAt {
                Text("Last connected \(lastConnectedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(scopes.count) approved access scope\(scopes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, role: .destructive, action: action)
                    .font(.caption)
                    .disabled(actionDisabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func deviceSymbol(_ kind: AdoptedClientKind?) -> String {
        switch kind {
        case .some(.mobile): "iphone"
        case .some(.macClient): "laptopcomputer"
        case nil: "desktopcomputer.and.macbook"
        }
    }

    private func clientKindTitle(_ kind: AdoptedClientKind?) -> String {
        switch kind {
        case .some(.mobile): "iPhone client"
        case .some(.macClient): "Mac client"
        case nil: "Harc client"
        }
    }

    private func deviceFingerprint(_ deviceID: DeviceID) -> String {
        let value = deviceID.description.uppercased()
        return stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(4, value.count - offset))
            return String(value[start..<end])
        }.joined(separator: " ")
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
