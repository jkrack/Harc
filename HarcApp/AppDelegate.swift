import AppKit
import SwiftUI
import HarcAudio
import HarcClient
import HarcStore
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
    private var store: RecordingStore?
    private var recordingsVM: RecordingsViewModel?
    private var detailWindows: [String: TranscriptionDetailWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            await self?.bootstrapStore()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self

        pop.contentSize = NSSize(width: 400, height: 400)

        self.statusItem = item
        self.popover = pop

        // Pre-launch the daemon in the background so ⌘R doesn't have to wait for
        // model load. Failure is logged and retried lazily on next recording start.
        Task { [launcher] in
            do {
                _ = try await launcher.ensureRunning()
            } catch {
                FileHandle.standardError.write(Data(
                    "harc: background daemon launch failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

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

            // Pipe transcript updates into the UI.
            Task { [weak self, transcriber] in
                for await update in await transcriber.updates {
                    await MainActor.run {
                        self?.state.appendPreview(update.joinedTextSoFar)
                    }
                }
            }

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
            if let store = self.store {
                let startedAt = result.wavURL.startedAtFromHarcPath() ?? Date()
                let transcriptText = result.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                let rec = Recording(
                    wavPath: result.wavURL.path,
                    txtPath: result.txtURL?.path,
                    jsonPath: result.jsonURL?.path,
                    startedAt: startedAt,
                    endedAt: Date(),
                    transcriptText: transcriptText
                )
                _ = try? await store.upsert(rec)
            }
            notifyRecordingSaved(result: result)
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

    private func openDetail(for recording: Recording) {
        if let existing = detailWindows[recording.wavPath] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            }
        )
        detailWindows[recording.wavPath] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deleteRecording(recording: Recording) {
        guard let id = recording.id, let vm = recordingsVM else { return }
        Task {
            try? await vm.delete(id: id)
        }
        // Also trash the files on disk.
        let fm = FileManager.default
        let paths = [recording.wavPath, recording.txtPath, recording.jsonPath].compactMap { $0 }
        for path in paths {
            try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        detailWindows[recording.wavPath]?.close()
        detailWindows.removeValue(forKey: recording.wavPath)
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

    private func bootstrapStore() async {
        do {
            let store = try await RecordingStore.onDisk()
            self.store = store

            // Ingest existing filesystem recordings.
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()

            let vm = RecordingsViewModel(store: store)
            vm.start()
            self.recordingsVM = vm

            // Mount into SwiftUI environment.
            await refreshPopoverRoot()
        } catch {
            FileHandle.standardError.write(Data(
                "harc: store init failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    private func refreshPopoverRoot() async {
        guard let vm = recordingsVM, let pop = popover else { return }
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] rec in
                self?.openDetail(for: rec)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        .environmentObject(state)
        .environmentObject(vm)
        .environmentObject(prefs)

        pop.contentViewController = NSHostingController(rootView: root)
    }
}
