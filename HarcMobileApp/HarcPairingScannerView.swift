@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct HarcPairingScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor @Sendable (String) -> Void
    let onFailure: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.makeViewController()
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: UIViewController,
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
            label: "com.harc.mobile.pairing-camera"
        )
        private let onCode: @MainActor (String) -> Void
        private let onFailure: @MainActor (String) -> Void
        private var delivered = false
        private var isActive = false
        private var isConfigured = false

        init(
            onCode: @escaping @MainActor @Sendable (String) -> Void,
            onFailure: @escaping @MainActor @Sendable (String) -> Void
        ) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        @MainActor
        func makeViewController() -> UIViewController {
            let controller = HarcPairingPreviewViewController(session: session)
            sessionQueue.async { [weak self] in
                self?.isActive = true
                self?.configure()
            }
            return controller
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                isActive = false
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configure() {
            guard isActive, !isConfigured else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else {
                        Task { @MainActor [weak self] in
                            self?.onFailure("Camera access is required to scan the Host pairing code.")
                        }
                        return
                    }
                    self?.sessionQueue.async { [weak self] in
                        self?.configure()
                    }
                }
                return
            case .denied, .restricted:
                Task { @MainActor [weak self] in
                    self?.onFailure(
                        "Camera access is required to scan the Host pairing code. Enable Camera for Harc in Settings."
                    )
                }
                return
            case .authorized:
                break
            @unknown default:
                Task { @MainActor [weak self] in
                    self?.onFailure("The camera authorization state is unavailable.")
                }
                return
            }
            do {
                guard let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                ) else { throw HarcScannerError.noCamera }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else {
                    throw HarcScannerError.configuration
                }
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw HarcScannerError.configuration
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: sessionQueue)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                isConfigured = true
                session.startRunning()
            } catch {
                Task { @MainActor [weak self] in
                    self?.onFailure(error.localizedDescription)
                }
            }
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
                  code.utf8.count <= 1_400,
                  code.hasPrefix("harc-pair://v1/") else { return }
            delivered = true
            session.stopRunning()
            Task { @MainActor [onCode] in onCode(code) }
        }
    }
}

@MainActor
final class HarcPairingPreviewViewController: UIViewController {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let guide = ScannerGuideView(frame: .zero)

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        root.layer.addSublayer(previewLayer)
        root.addSubview(guide)
        view = root
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        guide.frame = view.bounds
    }
}

private final class ScannerGuideView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        UIColor.black.withAlphaComponent(0.35).setFill()
        UIRectFill(rect)
        let side = min(rect.width - 56, 300)
        let frame = CGRect(
            x: (rect.width - side) / 2,
            y: (rect.height - side) / 2,
            width: side,
            height: side
        )
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 24)
        path.fill(with: .clear, alpha: 1)
        UIColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
    }
}

private enum HarcScannerError: LocalizedError {
    case noCamera
    case configuration

    var errorDescription: String? {
        switch self {
        case .noCamera: "No rear camera is available."
        case .configuration: "The camera could not start QR scanning."
        }
    }
}
