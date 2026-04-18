import AppKit
import SwiftUI
import HarcAudio
import HarcClient
import HarcUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()
    private let state = RecordingState()
    private let prefs = HarcPreferences.shared
    private var settingsWindow: SettingsWindowController?
    private lazy var recordingsIndex = RecordingsIndex(baseDirectory: prefs.destinationURL)
    private var detailWindows: [URL: TranscriptionDetailWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self

        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] entry in
                self?.openDetail(for: entry)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        .environmentObject(state)
        .environmentObject(recordingsIndex)
        .environmentObject(prefs)

        pop.contentViewController = NSHostingController(rootView: root)
        pop.contentSize = NSSize(width: 400, height: 400)

        self.statusItem = item
        self.popover = pop
        recordingsIndex.refresh()

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            Task { await self?.toggleRecording() }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func toggleRecording() async {
        if state.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard session == nil else { return }

        updateMenuBarIcon(recording: true)
        state.markStarted(at: Date())

        do {
            _ = try await launcher.ensureRunning()
            let client = HarcSTTClient()
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                chunkDurationSeconds: prefs.chunkDurationSeconds
            )
            let session = RecordingSession(
                mic: MicCapture(),
                systemAudio: SystemAudioCapture(),
                destination: RecordingDestination(baseDirectory: prefs.destinationURL),
                transcriber: transcriber
            )
            self.session = session
            try await session.start(at: state.recordingStartedAt ?? Date())
        } catch {
            presentError(error)
            resetAfterFailure()
        }
    }

    private func stopRecording() async {
        guard let session else { return }
        do {
            let result = try await session.stop()
            state.markStopped(wavURL: result.wavURL, txtURL: result.txtURL, jsonURL: result.jsonURL)
            notifyRecordingSaved(result: result)
            recordingsIndex.refresh()
        } catch {
            presentError(error)
        }
        resetAfterFailure()
    }

    private func resetAfterFailure() {
        session = nil
        if state.isRecording {
            state.markStopped(
                wavURL: URL(fileURLWithPath: "/dev/null"),
                txtURL: nil,
                jsonURL: nil
            )
        }
        updateMenuBarIcon(recording: false)
    }

    private func updateMenuBarIcon(recording: Bool, on item: NSStatusItem? = nil) {
        let target = item ?? statusItem
        guard let target else { return }
        let symbol = recording ? "record.circle.fill" : "waveform"
        let label = recording ? "Harc — recording" : "Harc"
        target.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
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

    private func openDetail(for entry: RecordingEntry) {
        if let existing = detailWindows[entry.wavURL] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = TranscriptionDetailWindowController(
            entry: entry,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([entry.wavURL])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(entry: entry)
            }
        )
        detailWindows[entry.wavURL] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deleteRecording(entry: RecordingEntry) {
        let fm = FileManager.default
        for url in [entry.wavURL, entry.txtURL, entry.jsonURL].compactMap({ $0 }) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        detailWindows[entry.wavURL]?.close()
        detailWindows.removeValue(forKey: entry.wavURL)
        recordingsIndex.refresh()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController(prefs: prefs)
        settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
