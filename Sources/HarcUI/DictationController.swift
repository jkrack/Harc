import Foundation
import AVFoundation
import HarcAudio
import HarcClient

/// Typed transform failures the controller can phrase for the user — thrown
/// by the app's transform closure (AppDelegate) so the fallback notice can
/// say *why* a mode didn't run instead of a generic "unavailable".
public enum DictationTransformFailure: Error, Equatable {
    /// The mode's LLM isn't downloaded. Associated value is the model's
    /// display name (tier), for the notice.
    case modelNotInstalled(String)
}

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
    /// Per-app rule seam: frontmost bundle ID → the mode whose activation
    /// rules claim it, if any. Consulted once per session, at start.
    private let ruleMode: @MainActor (String?) -> DictationMode?
    /// Cold-LLM check seam: returns the model's display name when the mode's
    /// transform model still needs a multi-GB load, nil when it's warm (or
    /// unresolvable — failures surface at transform time).
    private let transformColdModelName: ((DictationMode) async -> String?)?
    /// Preloads the mode's transform model so the visible loading phase
    /// covers exactly the load, not the generation. Errors are ignored here —
    /// the transform call reports them via the raw fallback.
    private let preloadTransformModel: ((DictationMode) async -> Void)?
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
    /// The mode resolved for the current session at start (one-shot hotkey >
    /// per-app rule > active mode). Frozen so a frontmost-app change mid-
    /// session can't switch modes between capture and transform.
    private var sessionMode: DictationMode?
    /// Set when the user releases the hotkey while start() is still in its
    /// pre-capture phase (e.g. the mic-permission prompt is up). start()
    /// checks it after each await and aborts cleanly.
    private var abortRequested = false
    /// When the current session entered `.listening` — drives the long-session
    /// cancel confirmation.
    private var listeningSince: Date?
    private var cancelConfirmResetTask: Task<Void, Never>?
    /// The app that delivered the deep link that initiated the current
    /// session, captured at link receipt. Insertion NEVER targets it — a
    /// webpage that triggered dictation must not receive the transcript.
    private var deepLinkOrigin: (bundleID: String?, name: String?)?
    /// Staged by the deep-link entry points; consumed (and cleared) by the
    /// next start() so origin is strictly per-session.
    private var nextSessionDeepLinkOrigin: (bundleID: String?, name: String?)?
    private var deepLinkConfirmExpiryTask: Task<Void, Never>?
    /// Harc's own bundle id — deep links fired while Harc is frontmost skip
    /// the confirmation (the gesture was in our own UI). Injectable for tests.
    private let harcBundleID: String

    public init(
        state: DictationState,
        recordingState: RecordingState,
        prefs: HarcPreferences,
        recorderFactory: @escaping @MainActor () -> any DictationRecording,
        transcribe: @escaping (String) async throws -> String,
        paster: any DictationPasting,
        activeMode: @escaping @MainActor () -> DictationMode = { DictationMode.builtIns[0] },
        transform: ((String, DictationMode, String?) async throws -> String)? = nil,
        ruleMode: @escaping @MainActor (String?) -> DictationMode? = { _ in nil },
        transformColdModelName: ((DictationMode) async -> String?)? = nil,
        preloadTransformModel: ((DictationMode) async -> Void)? = nil,
        captureContext: @escaping @MainActor (Bool, Bool) -> DictationContext = { selection, clipboard in
            SelectionContextReader.capture(selectedText: selection, clipboard: clipboard)
        },
        micPermission: (() async -> MicPermission)? = nil,
        ensureDaemonReady: ((@escaping @MainActor () -> Void) async throws -> Void)? = nil,
        cancelConfirmThreshold: TimeInterval = 30,
        harcBundleID: String = Bundle.main.bundleIdentifier ?? "com.harc.app"
    ) {
        self.state = state
        self.recordingState = recordingState
        self.prefs = prefs
        self.recorderFactory = recorderFactory
        self.transcribe = transcribe
        self.paster = paster
        self.activeMode = activeMode
        self.transform = transform
        self.ruleMode = ruleMode
        self.transformColdModelName = transformColdModelName
        self.preloadTransformModel = preloadTransformModel
        self.captureContext = captureContext
        self.micPermission = micPermission ?? Self.systemMicPermission
        self.ensureDaemonReady = ensureDaemonReady
        self.cancelConfirmThreshold = cancelConfirmThreshold
        self.harcBundleID = harcBundleID
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

    /// Toggle semantics regardless of the trigger-style pref — for one-shot
    /// invokers with no key-up to pair with (menu items, bridge actions).
    /// Deep links must NOT call this directly — they go through
    /// `requestDeepLinkDictation` so the mic never opens on a bare URL.
    public func toggleDictation(oneShot mode: DictationMode? = nil) {
        if state.isActive {
            Task { await stopAndInsert() }
        } else {
            if let mode { oneShotMode = mode }
            Task { await start() }
        }
    }

    // MARK: Deep links (harc://dictate)

    /// Entry point for `harc://dictate`. Security posture (a URL can be
    /// fired by any app, including a webpage after the browser's open-URL
    /// prompt):
    /// - The mic never opens on a bare link: unless Harc itself is frontmost
    ///   at link receipt, a confirmation is surfaced on the HUD and capture
    ///   starts only on the user's Start click.
    /// - A second link while a *link-initiated* session is listening cancels
    ///   it (no insert) — never stop-and-insert into the requester's page.
    /// - A link during a user-initiated (hotkey) session is ignored: a
    ///   webpage must not be able to end the user's own dictation.
    public func requestDeepLinkDictation(oneShot mode: DictationMode?) {
        if state.isActive {
            if deepLinkOrigin != nil {
                Task { await cancel(bypassConfirm: true) }
            } else {
                FileHandle.standardError.write(Data(
                    "harc: ignoring harc://dictate during a user-initiated dictation\n".utf8
                ))
            }
            return
        }
        // Requester = frontmost at link receipt (read before any UI moves).
        let requesterID = paster.frontmostBundleID()
        let requesterName = paster.frontmostAppName()
        if requesterID == harcBundleID {
            // The gesture happened in our own UI — no confirmation needed.
            nextSessionDeepLinkOrigin = (requesterID, requesterName)
            if let mode { oneShotMode = mode }
            Task { await start() }
            return
        }
        state.setPendingDeepLink(DictationDeepLinkRequest(
            mode: mode,
            requesterBundleID: requesterID,
            requesterName: requesterName
        ))
        deepLinkConfirmExpiryTask?.cancel()
        deepLinkConfirmExpiryTask = Task { [weak state] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            state?.setPendingDeepLink(nil)
        }
    }

    /// User clicked Start on the deep-link confirmation.
    public func confirmPendingDeepLink() {
        guard let request = state.pendingDeepLink else { return }
        deepLinkConfirmExpiryTask?.cancel()
        deepLinkConfirmExpiryTask = nil
        state.setPendingDeepLink(nil)
        nextSessionDeepLinkOrigin = (request.requesterBundleID, request.requesterName)
        if let mode = request.mode { oneShotMode = mode }
        Task { await start() }
    }

    /// User dismissed the deep-link confirmation (or it expired).
    public func dismissPendingDeepLink() {
        deepLinkConfirmExpiryTask?.cancel()
        deepLinkConfirmExpiryTask = nil
        state.setPendingDeepLink(nil)
    }

    /// The mode governing the current session. `sessionMode` is frozen at
    /// start; before that (or if start never resolved one) fall back live.
    private func currentMode() -> DictationMode {
        sessionMode ?? oneShotMode ?? activeMode()
    }

    public func start() async {
        guard !state.isActive else { return }
        deepLinkOrigin = nextSessionDeepLinkOrigin
        nextSessionDeepLinkOrigin = nil
        // Mutual exclusion: the mic + daemon are single-user resources.
        guard !recordingState.isRecording else {
            onBlockedByRecording()
            return
        }
        abortRequested = false
        // Resolve the session's mode ONCE, against the app the user is
        // actually dictating into: one-shot hotkey > per-app rule > active.
        // Read frontmost first — before any of our UI can shift focus.
        let frontmost = paster.frontmostBundleID()
        let active = activeMode()
        let ruleMatch = oneShotMode == nil ? ruleMode(frontmost) : nil
        let mode = oneShotMode ?? ruleMatch ?? active
        sessionMode = mode
        state.setSessionModeOverride(
            mode.id == active.id ? nil : mode,
            viaRule: ruleMatch != nil
        )
        // Super Mode: snapshot the working context FIRST — before the HUD
        // appears (the first setPhase shows it) and before the user's
        // focus/selection can change. Privacy guard: never read selection or
        // clipboard out of a deny-listed app (password managers, …).
        var capturedContext = DictationContext.empty
        if mode.wantsContext {
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
            sessionMode = nil
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
            sessionMode = nil
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
            sessionMode = nil
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
            sessionMode = nil
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
            sessionMode = nil
            state.setPhase(.error(Self.humanMessage(for: error)))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            oneShotMode = nil
            sessionMode = nil
            state.setPhase(.error("No speech detected — check that the waveform moves when you talk"))
            return
        }

        let mode = currentMode()
        oneShotMode = nil
        sessionMode = nil
        let output = await applyMode(to: trimmed, mode: mode)

        state.setPhase(.inserting)
        // Link-initiated sessions never insert into the app that delivered
        // the link — a webpage that triggered dictation must not receive the
        // transcript. Copy-only with an explicit notice instead.
        if let origin = deepLinkOrigin,
           let originID = origin.bundleID,
           frontmost == originID {
            paster.copyOnly(output)
            onDelivered(DictationHistoryEntry(
                text: output,
                rawText: output == trimmed ? nil : trimmed,
                modeName: mode.name,
                targetAppName: frontmostName,
                delivery: .copied
            ))
            state.setNotice(nil)
            state.setPhase(.done(DictationDeliveryOutcome(
                kind: .copied,
                message: "Copied — not inserted into \(origin.name ?? "the app that requested dictation")"
            )))
            return
        }
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

        // A cold LLM is a multi-GB load — show it honestly instead of hiding
        // it under the mode name. Preload so the loading phase covers exactly
        // the load; preload failures resurface from the transform call below.
        if let coldName = await transformColdModelName?(mode) {
            state.setPhase(.loadingTransformModel(coldName))
            await preloadTransformModel?(mode)
        }
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
        } catch let failure as DictationTransformFailure {
            switch failure {
            case .modelNotInstalled(let modelName):
                state.setNotice(
                    "\(mode.name) needs \(modelName) — download it in Settings → Models. Inserted raw text"
                )
            }
            return raw
        } catch {
            state.setNotice("\(mode.name) unavailable — inserted raw text")
            return raw
        }
    }

    /// Phrase daemon/client errors for a human. Raw error codes like
    /// `model_not_loaded` describe the first-run download, not a fault.
    nonisolated static func humanMessage(for error: Error) -> String {
        if let client = error as? ClientError {
            switch client {
            case .transcribeFailed(let code, _) where code == "model_not_loaded":
                return "Speech model is still downloading — try again shortly"
            case .timeout:
                return "Speech engine took too long — try again shortly"
            case .daemonNotReachable, .daemonLaunchFailed:
                return "Speech engine isn't running — it restarts on the next try"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Cancel the current session. Long sessions (past
    /// `cancelConfirmThreshold`) arm a confirmation first — the second call
    /// within a few seconds actually discards. Mirrors SuperWhisper's
    /// accidental-loss guard.
    public func cancel(bypassConfirm: Bool = false) async {
        guard state.isActive else {
            // Dismiss a lingering error/done afterglow.
            if case .idle = state.phase {} else { state.setPhase(.idle) }
            return
        }
        if !bypassConfirm,
           case .listening = state.phase,
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
        sessionMode = nil
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
