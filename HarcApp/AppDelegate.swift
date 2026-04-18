import AppKit
import HarcAudio
import HarcClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        let menu = NSMenu()

        let start = NSMenuItem(
            title: "Start Recording",
            action: #selector(startRecording),
            keyEquivalent: "r"
        )
        start.target = self
        menu.addItem(start)
        self.startMenuItem = start

        let stop = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: "s"
        )
        stop.target = self
        stop.isEnabled = false
        menu.addItem(stop)
        self.stopMenuItem = stop

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Harc",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        self.statusItem = item
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func startRecording() {
        guard session == nil else { return }

        startMenuItem?.isEnabled = false
        stopMenuItem?.isEnabled = true
        if let item = statusItem { updateMenuBarIcon(recording: true, on: item) }

        Task {
            do {
                // Ensure daemon is running before the first chunk.
                _ = try await self.launcher.ensureRunning()
                let client = HarcSTTClient()
                let transcriber = ChunkedTranscriber(
                    client: client,
                    diarize: true,
                    chunkDurationSeconds: 60.0
                )
                let session = RecordingSession(
                    mic: MicCapture(),
                    systemAudio: SystemAudioCapture(),
                    destination: RecordingDestination(baseDirectory: RecordingDestination.defaultBaseDirectory()),
                    transcriber: transcriber
                )
                self.session = session
                try await session.start(at: Date())
            } catch {
                self.presentError(error)
                self.resetUI()
            }
        }
    }

    @objc private func stopRecording() {
        guard let session else { return }
        Task {
            do {
                let result = try await session.stop()
                self.notifyRecordingSaved(result: result)
            } catch {
                self.presentError(error)
            }
            self.resetUI()
        }
    }

    private func resetUI() {
        self.session = nil
        startMenuItem?.isEnabled = true
        stopMenuItem?.isEnabled = false
        if let item = statusItem { updateMenuBarIcon(recording: false, on: item) }
    }

    private func updateMenuBarIcon(recording: Bool, on item: NSStatusItem) {
        let symbol = recording ? "record.circle.fill" : "waveform"
        let label = recording ? "Harc — recording" : "Harc"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    private func notifyRecordingSaved(result: RecordingResult) {
        let alert = NSAlert()
        alert.messageText = "Recording saved"
        if result.txtURL != nil {
            alert.informativeText = "Audio, transcript, and structured JSON written next to each other.\n\n\(result.wavURL.path)"
        } else {
            alert.informativeText = result.wavURL.path
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([result.wavURL])
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
