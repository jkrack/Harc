import Foundation
import AVFoundation
import HarcAudio

/// Orchestrates the dictation flow: capture a short mic clip, transcribe it via
/// the warm STT daemon, and insert the text at the cursor in the frontmost app.
/// Runs alongside — and mutually exclusive with — the meeting recorder.
@MainActor
public final class DictationController {
    public enum MicPermission: Equatable, Sendable {
        case granted
        case denied
        /// Not yet determined — a system prompt will appear.
        case undetermined
    }

    public let state: DictationState
    private let recordingState: RecordingState
    private let prefs: HarcPreferences
    private let recorderFactory: @MainActor () -> any DictationRecording
    private let transcribe: (String) async throws -> String
    private let paster: any DictationPasting
    /// The mode to apply to the next transcript. Injected as a closure so the
    /// controller stays decoupled from the mode store.
    private let activeMode: @MainActor () -> DictationMode
    /// LLM transform seam: (raw text, mode, context block) → transformed
    /// text. nil disables post-processing (everything inserts raw). Errors
    /// trigger raw fallback.
    private let transform: ((String, DictationMode, String?) async throws -> String)?
    /// Context-capture seam (Super Mode): (wantSelectedText, wantClipboard) →
    /// snapshot. Defaults to the live `SelectionContextReader`.
    private let captureContext: @MainActor (Bool, Bool) -> DictationContext
    /// Mic-permission preflight seam. Returns the current authorization,
    /// requesting it (system prompt) when undetermined. Runs BEFORE capture so
    /// the prompt never races the push-to-talk key-hold.
    private let micPermission: () async -> MicPermission
    /// Daemon readiness seam. Awaited before transcription; calls the given
    /// closure first when the daemon is cold so the UI can show a loading
    /// state. Also fired (result ignored) at dictation start to pre-warm.
    private let ensureDaemonReady: ((@escaping @MainActor () -> Void) async throws -> Void)?
    /// Sessions longer than this ask for confirmation before cancel discards
    /// the audio. Injectable for tests.
    private let cancelConfirmThreshold: TimeInterval
    /// Called when a start is refused because a meeting recording is active,
    /// so the caller can surface a hint.
    public var onBlockedByRecording: () -> Void = {}
    /// Called after text is delivered (pasted or copied) so the caller can
    /// record dictation history. Cancelled sessions never reach this.
    public var onDelivered: (DictationHistoryEntry) -> Void = { _ in }
    /// Called when a delivery fell back to copy because Accessibility is
    /// missing — the caller may present the permission UI.
    public var onNeedsAccessibility: () -> Void = {}

    private var activeRecorder: (any DictationRecording)?
    private var levelsTask: Task<Void, Never>?
    /// Mode override for the current session (per-mode hotkey). One-shot:
    /// consumed by this session only, never persisted as the active mode.
    private var oneShotMode: DictationMode?
    /// Set when the user releases the hotkey while start() is still in its
    /// pre-capture phase (e.g. the mic-permission prompt is up). start()
    /// checks it after each await and aborts cleanly.
    private var abortRequested = false
    /// When the current session entered `.listening` — drives the long-session
    /// cancel confirmation.
    private var listeningSince: Date?
    private var cancelConfirmResetTask: Task<Void, Never>?

    public init(
        state: DictationState,
        recordingState: RecordingState,
        prefs: HarcPreferences,
        recorderFactory: @escaping @MainActor () -> any DictationRecording,
        transcribe: @escaping (String) async throws -> String,
        paster: any DictationPasting,
        activeMode: @escaping @MainActor () -> DictationMode = { DictationMode.builtIns[0] },
        transform: ((String, DictationMode, String?) async throws -> String)? = nil,
        captureContext: @escaping @MainActor (Bool, Bool) -> DictationContext = { selection, clipboard in
            SelectionContextReader.capture(selectedText: selection, clipboard: clipboard)
        },
        micPermission: (() async -> MicPermission)? = nil,
        ensureDaemonReady: ((@escaping @MainActor () -> Void) async throws -> Void)? = nil,
        cancelConfirmThreshold: TimeInterval = 30
    ) {
        self.state = state
        self.recordingState = recordingState
        self.prefs = prefs
        self.recorderFactory = recorderFactory
        self.transcribe = transcribe
        self.paster = paster
        self.activeMode = activeMode
        self.transform = transform
        self.captureContext = captureContext
        self.micPermission = micPermission ?? Self.systemMicPermission
        self.ensureDaemonReady = ensureDaemonReady
        self.cancelConfirmThreshold = cancelConfirmThreshold
    }

    public var isActive: Bool { state.isActive }

    /// Route a hotkey event through the configured trigger style.
    public func handleHotkey(_ event: DictationHotkeyEvent) {
        let action = DictationTriggerRouter.action(
            style: prefs.dictationTriggerStyle,
            event: event,
            isActive: state.isActive
        )
        switch action {
        case .start: Task { await start() }
        case .stop: Task { await stopAndInsert() }
        case .none: break
        }
    }

    /// Route a per-mode hotkey: same trigger semantics, but the session runs
    /// with `mode` as a one-shot override — the persisted active mode is
    /// untouched.
    public func handleModeHotkey(_ event: DictationHotkeyEvent, mode: DictationMode) {
        let action = DictationTriggerRouter.action(
            style: prefs.dictationTriggerStyle,
            event: event,
            isActive: state.isActive
        )
        switch action {
        case .start:
            oneShotMode = mode
            Task { await start() }
        case .stop: Task { await stopAndInsert() }
        case .none: break
        }
    }

    /// The mode governing the current session.
    private func currentMode() -> DictationMode {
        oneShotMode ?? activeMode()
    }

    public func start() async {
        guard !state.isActive else { return }
        // Mutual exclusion: the mic + daemon are single-user resources.
        guard !recordingState.isRecording else {
            onBlockedByRecording()
            return
        }
        abortRequested = false
        // Super Mode: snapshot the working context FIRST — before the HUD
        // appears (the first setPhase shows it) and before the user's
        // focus/selection can change. Privacy guard: never read selection or
        // clipboard out of a deny-listed app (password managers, …).
        let mode = currentMode()
        var capturedContext = DictationContext.empty
        if mode.wantsContext {
            let frontmost = paster.frontmostBundleID()
            if !PasteDenyList.isDenied(frontmost, in: prefs.pasteDenyListBundleIDs) {
                capturedContext = captureContext(
                    mode.includeSelectedText,
                    mode.includeClipboard
                )
            }
        }

        // Mic preflight — BEFORE capture starts, so the one-time system
        // prompt can't race the push-to-talk key-hold.
        state.setPhase(.requestingMic)
        state.setContext(capturedContext)
        switch await micPermission() {
        case .denied:
            oneShotMode = nil
            state.setPhase(.error("Microphone access is off — enable it in System Settings → Privacy & Security → Microphone"))
            return
        case .granted, .undetermined:
            break
        }
        // The user may have released the key while the permission prompt was
        // up — abort cleanly instead of racing recorder start/stop.
        if abortRequested {
            abortRequested = false
            oneShotMode = nil
            state.setPhase(.idle)
            return
        }

        state.setPhase(.listening)
        listeningSince = Date()

        // Pre-warm the daemon while the user speaks — by the time they stop,
        // the model is usually loaded. Failures surface at transcribe time.
        if let ensureDaemonReady {
            Task { try? await ensureDaemonReady({}) }
        }

        let recorder = recorderFactory()
        activeRecorder = recorder
        levelsTask = Task { [weak state] in
            for await value in recorder.levels {
                state?.pushLevel(value)
            }
        }

        do {
            try await recorder.start()
        } catch {
            levelsTask?.cancel()
            levelsTask = nil
            activeRecorder = nil
            oneShotMode = nil
            // Only surface if we haven't already been superseded by a stop.
            if case .listening = state.phase {
                state.setPhase(.error(error.localizedDescription))
            }
        }
    }

    public func stopAndInsert() async {
        // Released during the pre-capture phase (mic prompt / preflight):
        // nothing was recorded yet — ask start() to unwind.
        if case .requestingMic = state.phase {
            abortRequested = true
            return
        }
        guard case .listening = state.phase, let recorder = activeRecorder else { return }
        state.setConfirmingCancel(false)
        listeningSince = nil
        // Read frontmost target BEFORE anything can hide/refocus.
        let frontmost = paster.frontmostBundleID()
        let frontmostName = paster.frontmostAppName()

        let wav: URL
        do {
            state.setPhase(.transcribing)
            wav = try await recorder.stop()
        } catch {
            cleanup()
            oneShotMode = nil
            state.setPhase(.error(error.localizedDescription))
            return
        }
        cleanup()
        defer { try? FileManager.default.removeItem(at: wav) }

        let text: String
        do {
            // Cold daemon → visible "Loading speech model…" instead of an
            // unexplained long "Transcribing…".
            if let ensureDaemonReady {
                try await ensureDaemonReady { [weak state] in
                    state?.setPhase(.loadingModel)
                }
            }
            state.setPhase(.transcribing)
            text = try await transcribe(wav.path)
        } catch {
            oneShotMode = nil
            state.setPhase(.error(error.localizedDescription))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            oneShotMode = nil
            state.setPhase(.error("No speech detected — check that the waveform moves when you talk"))
            return
        }

        let mode = currentMode()
        oneShotMode = nil
        let output = await applyMode(to: trimmed, mode: mode)

        state.setPhase(.inserting)
        // The deny-list always applies (never paste into password fields /
        // Harc itself); "insert at cursor" itself is a preference.
        let decision = AutoPasteGuard.decide(
            enabled: prefs.dictationInsertsAtCursor,
            shiftHeld: false,
            frontmostBundleID: frontmost,
            deniedBundleIDs: prefs.pasteDenyListBundleIDs
        )
        let delivery: DictationHistoryEntry.Delivery
        let outcome: DictationDeliveryOutcome
        switch decision {
        case .paste:
            do {
                try await paster.insert(output)
                delivery = .pasted
                outcome = DictationDeliveryOutcome(
                    kind: .inserted,
                    message: state.notice ?? "Inserted into \(frontmostName ?? "the frontmost app")"
                )
            } catch {
                // Fall back to leaving it on the clipboard so the text isn't lost.
                paster.copyOnly(output)
                delivery = .copied
                let needsAX = (error as? FrontmostAppPaster.PasteError) == .accessibilityDenied
                outcome = DictationDeliveryOutcome(
                    kind: .copied,
                    message: needsAX
                        ? "Copied — grant Accessibility to insert at the cursor"
                        : "Copied — paste failed in \(frontmostName ?? "the frontmost app")",
                    needsAccessibility: needsAX
                )
                if needsAX { onNeedsAccessibility() }
            }
        case .skipDisabled:
            paster.copyOnly(output)
            delivery = .copied
            outcome = DictationDeliveryOutcome(
                kind: .copied,
                message: state.notice ?? "Copied to clipboard"
            )
        case .skipModifierHeld, .skipUnsafeTarget:
            paster.copyOnly(output)
            delivery = .copied
            outcome = DictationDeliveryOutcome(
                kind: .copied,
                message: "Copied — paste is blocked in \(frontmostName ?? "this app")"
            )
        }
        onDelivered(DictationHistoryEntry(
            text: output,
            rawText: output == trimmed ? nil : trimmed,
            modeName: mode.name,
            targetAppName: frontmostName,
            delivery: delivery
        ))
        state.setNotice(nil)
        state.setPhase(.done(outcome))
    }

    /// Route the raw transcript through the session's mode. Any transform
    /// failure (model missing, generation error, no transform wired) falls
    /// back to the raw transcript — the user's words are never lost.
    private func applyMode(to raw: String, mode: DictationMode) async -> String {
        guard mode.postProcess == .llm, !mode.instruction.isEmpty else { return raw }
        guard let transform else { return raw }

        state.setPhase(.transforming)
        do {
            // Context was snapshotted at start; render it for the prompt.
            // (nil when the mode didn't want context or capture was skipped.)
            let contextBlock = mode.wantsContext ? state.context.promptBlock : nil
            let transformed = try await transform(raw, mode, contextBlock)
            let trimmed = transformed.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty transform result is a failure — keep the raw words.
            guard !trimmed.isEmpty else {
                state.setNotice("\(mode.name) returned nothing — inserted raw text")
                return raw
            }
            return trimmed
        } catch {
            state.setNotice("\(mode.name) unavailable — inserted raw text")
            return raw
        }
    }

    /// Cancel the current session. Long sessions (past
    /// `cancelConfirmThreshold`) arm a confirmation first — the second call
    /// within a few seconds actually discards. Mirrors SuperWhisper's
    /// accidental-loss guard.
    public func cancel() async {
        guard state.isActive else {
            // Dismiss a lingering error/done afterglow.
            if case .idle = state.phase {} else { state.setPhase(.idle) }
            return
        }
        if case .listening = state.phase,
           let since = listeningSince,
           Date().timeIntervalSince(since) > cancelConfirmThreshold,
           !state.confirmingCancel {
            state.setConfirmingCancel(true)
            cancelConfirmResetTask?.cancel()
            cancelConfirmResetTask = Task { [weak state] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                state?.setConfirmingCancel(false)
            }
            return
        }
        cancelConfirmResetTask?.cancel()
        cancelConfirmResetTask = nil
        listeningSince = nil
        let recorder = activeRecorder
        cleanup()
        oneShotMode = nil
        await recorder?.cancel()
        state.setPhase(.idle)
    }

    /// Dismiss a `.done` / `.error` afterglow immediately.
    public func dismissAfterglow() {
        switch state.phase {
        case .done, .error: state.setPhase(.idle)
        default: break
        }
    }

    private func cleanup() {
        levelsTask?.cancel()
        levelsTask = nil
        activeRecorder = nil
    }

    /// Live AVFoundation mic authorization: requests when undetermined (this
    /// shows the one-time system prompt), never prompts once decided.
    private static func systemMicPermission() async -> MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}
