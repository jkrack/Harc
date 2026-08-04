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
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        context.coordinator.prepare(in: controller)
        return controller
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

        init(
            onCode: @escaping @MainActor @Sendable (String) -> Void,
            onFailure: @escaping @MainActor @Sendable (String) -> Void
        ) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        @MainActor
        func prepare(in controller: UIViewController) {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = controller.view.bounds
            controller.view.layer.addSublayer(preview)
            let guide = ScannerGuideView(frame: controller.view.bounds)
            guide.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(guide)
            sessionQueue.async { [weak self] in
                self?.configure()
            }
        }

        func stop() {
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configure() {
            guard AVCaptureDevice.authorizationStatus(for: .video)
                    == .authorized else {
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
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    throw HarcScannerError.configuration
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: sessionQueue)
                output.metadataObjectTypes = [.qr]
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

private final class ScannerGuideView: UIView {
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
        UIColor.clear.setFill()
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
