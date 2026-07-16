import Foundation
import HarcAudio

/// Orchestrates the dictation flow: capture a short mic clip, transcribe it via
/// the warm STT daemon, and insert the text at the cursor in the frontmost app.
/// Runs alongside — and mutually exclusive with — the meeting recorder.
@MainActor
public final class DictationController {
    public let state: DictationState
    private let recordingState: RecordingState
    private let prefs: HarcPreferences
    private let recorderFactory: @MainActor () -> any DictationRecording
    private let transcribe: (String) async throws -> String
    private let paster: any DictationPasting
    /// The mode to apply to the next transcript. Injected as a closure so the
    /// controller stays decoupled from the mode store.
    private let activeMode: @MainActor () -> DictationMode
    /// LLM transform seam: (raw text, mode) → transformed text. nil disables
    /// post-processing (everything inserts raw). Errors trigger raw fallback.
    private let transform: ((String, DictationMode) async throws -> String)?
    /// Called when a start is refused because a meeting recording is active,
    /// so the caller can surface a hint.
    public var onBlockedByRecording: () -> Void = {}

    private var activeRecorder: (any DictationRecording)?
    private var levelsTask: Task<Void, Never>?

    public init(
        state: DictationState,
        recordingState: RecordingState,
        prefs: HarcPreferences,
        recorderFactory: @escaping @MainActor () -> any DictationRecording,
        transcribe: @escaping (String) async throws -> String,
        paster: any DictationPasting,
        activeMode: @escaping @MainActor () -> DictationMode = { DictationMode.builtIns[0] },
        transform: ((String, DictationMode) async throws -> String)? = nil
    ) {
        self.state = state
        self.recordingState = recordingState
        self.prefs = prefs
        self.recorderFactory = recorderFactory
        self.transcribe = transcribe
        self.paster = paster
        self.activeMode = activeMode
        self.transform = transform
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

    public func start() async {
        guard !state.isActive else { return }
        // Mutual exclusion: the mic + daemon are single-user resources.
        guard !recordingState.isRecording else {
            onBlockedByRecording()
            return
        }
        state.setPhase(.listening)

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
            // Only surface if we haven't already been superseded by a stop.
            if case .listening = state.phase {
                state.setPhase(.error(error.localizedDescription))
            }
        }
    }

    public func stopAndInsert() async {
        guard case .listening = state.phase, let recorder = activeRecorder else { return }
        // Read frontmost target BEFORE anything can hide/refocus.
        let frontmost = paster.frontmostBundleID()
        state.setPhase(.transcribing)

        let wav: URL
        do {
            wav = try await recorder.stop()
        } catch {
            cleanup()
            state.setPhase(.error(error.localizedDescription))
            return
        }
        cleanup()
        defer { try? FileManager.default.removeItem(at: wav) }

        let text: String
        do {
            text = try await transcribe(wav.path)
        } catch {
            state.setPhase(.error(error.localizedDescription))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.setPhase(.idle)
            return
        }

        let output = await applyMode(to: trimmed)

        state.setPhase(.inserting)
        // Insertion is the whole point, so it's always "enabled"; the deny-list
        // still applies (never paste into password fields / Harc itself).
        let decision = AutoPasteGuard.decide(
            enabled: true,
            shiftHeld: false,
            frontmostBundleID: frontmost,
            deniedBundleIDs: prefs.pasteDenyListBundleIDs
        )
        switch decision {
        case .paste:
            do {
                try paster.insert(output)
            } catch {
                // Fall back to leaving it on the clipboard so the text isn't lost.
                paster.copyOnly(output)
            }
        case .skipDisabled, .skipModifierHeld, .skipUnsafeTarget:
            paster.copyOnly(output)
        }
        state.setPhase(.idle)
    }

    /// Route the raw transcript through the active mode. Any transform
    /// failure (model missing, generation error, no transform wired) falls
    /// back to the raw transcript — the user's words are never lost.
    private func applyMode(to raw: String) async -> String {
        let mode = activeMode()
        guard mode.postProcess == .llm, !mode.instruction.isEmpty else { return raw }
        guard let transform else { return raw }

        state.setPhase(.transforming)
        do {
            let transformed = try await transform(raw, mode)
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

    public func cancel() async {
        guard state.isActive else { return }
        let recorder = activeRecorder
        cleanup()
        await recorder?.cancel()
        state.setPhase(.idle)
    }

    private func cleanup() {
        levelsTask?.cancel()
        levelsTask = nil
        activeRecorder = nil
    }
}
