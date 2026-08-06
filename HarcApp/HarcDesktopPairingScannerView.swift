@preconcurrency import AVFoundation
import AppKit
import HarcProtocol
import QuartzCore
import SwiftUI

struct HarcDesktopPairingCamera: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum HarcDesktopPairingCodeFilter {
    static let maximumUTF8ByteCount = 1_400
    static let prefix = PairingTicketV1.uriPrefix

    static func accepts(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumUTF8ByteCount
            && value.hasPrefix(prefix)
            && value.unicodeScalars.allSatisfy {
                (0x21 ... 0x7E).contains($0.value)
            }
    }

    static func pastedCandidate(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return accepts(candidate) ? candidate : nil
    }
}

enum HarcDesktopPairingMetadataPolicy {
    static func qrObjectTypes(
        availableTypes: [AVMetadataObject.ObjectType]
    ) -> [AVMetadataObject.ObjectType]? {
        availableTypes.contains(.qr) ? [.qr] : nil
    }
}

enum HarcDesktopPairingCameraDiscovery {
    static func availableCameras() -> [HarcDesktopPairingCamera] {
        discoverySession().devices.map {
            HarcDesktopPairingCamera(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    static func device(withID id: String) -> AVCaptureDevice? {
        discoverySession().devices.first { $0.uniqueID == id }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
    }
}

struct HarcDesktopPairingScannerView: NSViewControllerRepresentable {
    let cameraID: String
    let onCode: @MainActor @Sendable (String) -> Void
    let onFailure: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure)
    }

    func makeNSViewController(context: Context) -> NSViewController {
        context.coordinator.makeViewController(cameraID: cameraID)
    }

    func updateNSViewController(
        _ nsViewController: NSViewController,
        context: Context
    ) {
        context.coordinator.selectCamera(cameraID)
    }

    static func dismantleNSViewController(
        _ nsViewController: NSViewController,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    final class Coordinator: NSObject,
        AVCaptureMetadataOutputObjectsDelegate,
        @unchecked Sendable
    {
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(
            label: "com.harc.desktop.pairing-camera"
        )
        private let onCode: @MainActor (String) -> Void
        private let onFailure: @MainActor (String) -> Void
        private var isActive = false
        private var selectedCameraID: String?
        private var delivered = false

        init(
            onCode: @escaping @MainActor @Sendable (String) -> Void,
            onFailure: @escaping @MainActor @Sendable (String) -> Void
        ) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        @MainActor
        func makeViewController(cameraID: String) -> NSViewController {
            let controller = HarcDesktopPairingPreviewViewController(
                session: session
            )
            sessionQueue.async { [weak self] in
                guard let self else { return }
                isActive = true
                configure(cameraID: cameraID)
            }
            return controller
        }

        func selectCamera(_ cameraID: String) {
            sessionQueue.async { [weak self] in
                guard let self,
                      isActive,
                      selectedCameraID != cameraID else { return }
                configure(cameraID: cameraID)
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                isActive = false
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configure(cameraID: String) {
            guard isActive else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        sessionQueue.async { [weak self] in
                            self?.configure(cameraID: cameraID)
                        }
                    } else {
                        reportFailure(
                            "Camera access is required to scan the Host pairing code."
                        )
                    }
                }
                return
            case .denied, .restricted:
                reportFailure(
                    "Camera access is required to scan the Host pairing code. Enable Camera for Harc in System Settings."
                )
                return
            case .authorized:
                break
            @unknown default:
                reportFailure("The camera authorization state is unavailable.")
                return
            }

            do {
                guard let camera = HarcDesktopPairingCameraDiscovery.device(
                    withID: cameraID
                ) else {
                    throw HarcDesktopPairingScannerError.noCamera
                }
                if session.isRunning { session.stopRunning() }
                let input = try AVCaptureDeviceInput(device: camera)
                try configureSession(input: input)
                selectedCameraID = cameraID
                delivered = false
                session.startRunning()
            } catch {
                reportFailure(error.localizedDescription)
            }
        }

        private func configureSession(input: AVCaptureDeviceInput) throws {
            let output = try attachMetadataOutput(input: input)
            guard let objectTypes = HarcDesktopPairingMetadataPolicy
                .qrObjectTypes(
                    availableTypes: output.availableMetadataObjectTypes
                ) else {
                removeMetadataOutput(output)
                throw HarcDesktopPairingScannerError.qrUnsupported
            }
            output.setMetadataObjectsDelegate(self, queue: sessionQueue)
            output.metadataObjectTypes = objectTypes
        }

        /// Attach and commit the input/output graph before consulting metadata
        /// capabilities. AVFoundation can report an empty availability list
        /// while a newly added output is still inside begin/commitConfiguration.
        private func attachMetadataOutput(
            input: AVCaptureDeviceInput
        ) throws -> AVCaptureMetadataOutput {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            for existing in session.outputs { session.removeOutput(existing) }
            for existing in session.inputs { session.removeInput(existing) }
            guard session.canAddInput(input) else {
                throw HarcDesktopPairingScannerError.configuration
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                throw HarcDesktopPairingScannerError.configuration
            }
            session.addOutput(output)
            return output
        }

        private func removeMetadataOutput(_ output: AVCaptureMetadataOutput) {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.outputs.contains(where: { $0 === output }) else {
                return
            }
            session.removeOutput(output)
        }

        private func reportFailure(_ message: String) {
            Task { @MainActor [onFailure] in onFailure(message) }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered,
                  let code = metadataObjects
                    .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                    .first(where: { $0.type == .qr })?.stringValue,
                  HarcDesktopPairingCodeFilter.accepts(code) else { return }
            delivered = true
            session.stopRunning()
            Task { @MainActor [onCode] in onCode(code) }
        }
    }
}

@MainActor
private final class HarcDesktopPairingPreviewViewController: NSViewController {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let guideLayer = CAShapeLayer()

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        root.layer?.addSublayer(previewLayer)
        guideLayer.fillColor = NSColor.clear.cgColor
        guideLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        guideLayer.lineWidth = 3
        root.layer?.addSublayer(guideLayer)
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        previewLayer.frame = view.bounds
        let side = min(view.bounds.width - 48, view.bounds.height - 36)
        let guideFrame = CGRect(
            x: (view.bounds.width - side) / 2,
            y: (view.bounds.height - side) / 2,
            width: side,
            height: side
        )
        guideLayer.path = CGPath(
            roundedRect: guideFrame,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )
        guideLayer.frame = view.bounds
    }
}

private enum HarcDesktopPairingScannerError: LocalizedError {
    case noCamera
    case configuration
    case qrUnsupported

    var errorDescription: String? {
        switch self {
        case .noCamera: "The selected camera is no longer available."
        case .configuration: "The camera could not start QR scanning."
        case .qrUnsupported:
            "The selected camera does not support QR scanning. Choose another camera or paste the Host pairing link."
        }
    }
}
