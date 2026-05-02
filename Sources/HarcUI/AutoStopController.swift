import Foundation
import Combine
import HarcAudio

/// Auto-stop safety state machine.
///
/// Observes a `RecordingSession`'s level stream plus wall-clock time since
/// recording began. Fires a warning 60 seconds before auto-stopping when
/// either condition is met:
///
/// - **Silence**: both mic and system-audio streams sit below `silenceDbCeiling`
///   (default −50 dBFS) for `silenceThresholdSeconds`. If system-audio capture
///   is unavailable, mic-only is used.
/// - **Hard cap**: wall-clock elapsed exceeds `hardCapSeconds`.
///
/// Exposes `phase` for SwiftUI and invokes `onAutoStop` when the 60-second
/// countdown runs out — the owner (AppDelegate) performs the actual stop.
@MainActor
public final class AutoStopController: ObservableObject {

    public enum StopReason: Sendable, Equatable {
        case silence
        case hardCap
    }

    public enum Phase: Equatable {
        case idle
        case watching
        case warning(secondsLeft: Int, reason: StopReason)
        /// The most recent recording was auto-stopped. Persists across tray
        /// opens until the user dismisses it. Cleared by `resetPostStop()`.
        case stoppedBanner(reason: StopReason, at: Date)
    }

    public struct Config: Sendable, Equatable {
        public var silenceEnabled: Bool
        public var silenceThresholdSeconds: TimeInterval
        public var silenceDbCeiling: Float
        public var hardCapEnabled: Bool
        public var hardCapSeconds: TimeInterval
        public var warningSeconds: Int

        public static let defaults = Config(
            silenceEnabled: true,
            silenceThresholdSeconds: 5 * 60,
            silenceDbCeiling: -50,
            hardCapEnabled: true,
            hardCapSeconds: 180 * 60,
            warningSeconds: 60
        )

        public init(
            silenceEnabled: Bool,
            silenceThresholdSeconds: TimeInterval,
            silenceDbCeiling: Float,
            hardCapEnabled: Bool,
            hardCapSeconds: TimeInterval,
            warningSeconds: Int
        ) {
            self.silenceEnabled = silenceEnabled
            self.silenceThresholdSeconds = silenceThresholdSeconds
            self.silenceDbCeiling = silenceDbCeiling
            self.hardCapEnabled = hardCapEnabled
            self.hardCapSeconds = hardCapSeconds
            self.warningSeconds = warningSeconds
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// Raw per-tick RMS of the two streams — exposed so the warning UI can
    /// show a mic/sys readout while the countdown runs.
    @Published public private(set) var lastMicDb: Float = -.infinity
    @Published public private(set) var lastSystemDb: Float = -.infinity

    /// Weighted + envelope-smoothed dBFS of the combined mic+sys signal,
    /// clamped to `[-60, 0]`. The silence detector reads this (not the raw
    /// per-stream RMS), so the bars the user sees and the countdown share one
    /// signal.
    @Published public private(set) var smoothedDb: Float = -60
    /// 5-band FFT magnitudes in `[0, 1]` — drives the menu bar icon.
    @Published public private(set) var fftBins: [Float] = Array(repeating: 0, count: 5)
    /// Rolling ~4-second history of normalized amplitude bars in `[0, 1]`, one
    /// entry per `amplitudeInterval` (1/24 s). Frozen in place on `.stoppedBanner`.
    @Published public private(set) var amplitudeHistory: [Float] = Array(repeating: 0, count: 96)

    public var config: Config

    /// Called when the 60 s countdown runs out. Owner performs the actual stop.
    public var onAutoStop: ((StopReason) -> Void)?

    /// Amplitude bar cadence — 96 bars × (1/24) s ≈ 4 s of history.
    public static let amplitudeInterval: TimeInterval = 1.0 / 24.0
    public static let amplitudeCapacity: Int = 96

    private var startedAt: Date?
    private var lastNonSilentAt: Date?
    private var levelsTask: Task<Void, Never>?
    private var tickTimer: Timer?

    private var amplitudeWindowMax: Float = 0
    private var amplitudeWindowStartedAt: Date?

    public init(config: Config = .defaults) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func begin(session: RecordingSession, startedAt: Date) {
        resetForBegin(startedAt: startedAt)

        levelsTask?.cancel()
        let stream = session.levels
        levelsTask = Task { @MainActor [weak self] in
            for await level in stream {
                self?.consume(level)
            }
        }

        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func resetForBegin(startedAt: Date) {
        self.startedAt = startedAt
        self.lastNonSilentAt = startedAt   // assume audio until proven silent
        phase = .watching
        amplitudeHistory = Array(repeating: 0, count: Self.amplitudeCapacity)
        amplitudeWindowMax = 0
        amplitudeWindowStartedAt = startedAt
        smoothedDb = Self.dbFloor
        fftBins = Array(repeating: 0, count: 5)
    }

    /// Stop monitoring. Called when the recording ends (for any reason).
    /// If `autoStopReason` is non-nil, the `stoppedBanner` persists for the tray
    /// banner. Otherwise the controller returns to `.idle`.
    public func end(autoStopReason: StopReason? = nil) {
        levelsTask?.cancel()
        levelsTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        startedAt = nil
        lastNonSilentAt = nil

        if let reason = autoStopReason {
            phase = .stoppedBanner(reason: reason, at: Date())
        } else {
            phase = .idle
        }
    }

    public func resetPostStop() {
        if case .stoppedBanner = phase { phase = .idle }
    }

    // MARK: - User actions from the countdown warning

    /// User pressed "Keep Recording" — dismiss warning, reset silence window.
    public func keepRecording() {
        keepRecording(at: Date())
    }

    private func keepRecording(at date: Date) {
        guard case .warning = phase else { return }
        lastNonSilentAt = date
        phase = .watching
    }

    /// User pressed "Stop Now" — request an immediate stop (counts as user action,
    /// not auto-stop, so no post-stop banner).
    public func stopNow() {
        guard case .warning(_, let reason) = phase else { return }
        phase = .watching
        onAutoStop?(reason)   // owner decides; reason is informational
    }

    // MARK: - Ticking

    /// Clamp/normalization floor used for the scope Y-axis and envelope.
    public static let dbFloor: Float = -60

    private func consume(_ level: AudioLevels, now: Date = Date()) {
        lastMicDb = level.micDb
        lastSystemDb = level.systemDb
        smoothedDb = level.smoothedDb
        fftBins = level.fftBins

        // Silence detection reads the *same* smoothed signal that drives the
        // bars — so a flatline on the scope corresponds exactly to the timer
        // running.
        if level.smoothedDb > config.silenceDbCeiling {
            lastNonSilentAt = now
        }

        // Accumulate amplitude bars. Each bar is the max normalized value seen in
        // the preceding `amplitudeInterval` window — a mini peak hold so fast
        // transients still register at the display cadence.
        if amplitudeWindowStartedAt == nil { amplitudeWindowStartedAt = now }
        let normalized = max(0, min(1, (level.smoothedDb - Self.dbFloor) / abs(Self.dbFloor)))
        amplitudeWindowMax = max(amplitudeWindowMax, normalized)
        if let windowStart = amplitudeWindowStartedAt,
           now.timeIntervalSince(windowStart) >= Self.amplitudeInterval {
            amplitudeHistory.append(amplitudeWindowMax)
            if amplitudeHistory.count > Self.amplitudeCapacity {
                amplitudeHistory.removeFirst(amplitudeHistory.count - Self.amplitudeCapacity)
            }
            amplitudeWindowMax = 0
            amplitudeWindowStartedAt = now
        }
    }

    private func tick(now: Date = Date()) {
        guard let startedAt else { return }
        let elapsed = now.timeIntervalSince(startedAt)

        // Hard cap takes precedence — a silent warning can be "kept" but
        // the cap is, by name, hard.
        if config.hardCapEnabled, elapsed >= config.hardCapSeconds {
            advanceWarning(reason: .hardCap, now: now)
            return
        }

        if config.silenceEnabled,
           let lastAudible = lastNonSilentAt,
           now.timeIntervalSince(lastAudible) >= config.silenceThresholdSeconds {
            advanceWarning(reason: .silence, now: now)
            return
        }

        // Not warning anymore — back to watching if we were.
        if case .warning = phase { phase = .watching }
    }

    private func advanceWarning(reason: StopReason, now: Date) {
        let totalBudget = config.warningSeconds
        let triggeredAt: Date
        switch reason {
        case .silence:
            triggeredAt = (lastNonSilentAt ?? now)
                .addingTimeInterval(config.silenceThresholdSeconds)
        case .hardCap:
            triggeredAt = (startedAt ?? now).addingTimeInterval(config.hardCapSeconds)
        }
        let elapsedIntoWarning = now.timeIntervalSince(triggeredAt)
        let remaining = max(0, totalBudget - Int(elapsedIntoWarning.rounded()))

        if remaining <= 0 {
            phase = .watching     // brief neutral state before AppDelegate ends us
            onAutoStop?(reason)
            return
        }

        switch phase {
        case .warning(_, let existingReason) where existingReason == reason:
            phase = .warning(secondsLeft: remaining, reason: reason)
        default:
            phase = .warning(secondsLeft: remaining, reason: reason)
        }
    }
}

extension AutoStopController {
    func testingBegin(startedAt: Date) {
        resetForBegin(startedAt: startedAt)
    }

    func testingConsume(
        smoothedDb: Float,
        micDb: Float? = nil,
        systemDb: Float? = nil,
        fftBins: [Float] = Array(repeating: 0, count: 5),
        now: Date
    ) {
        let db = smoothedDb
        consume(AudioLevels(
            micDb: micDb ?? db,
            systemDb: systemDb ?? db,
            smoothedDb: db,
            fftBins: fftBins
        ), now: now)
    }

    func testingTick(now: Date) {
        tick(now: now)
    }

    func testingKeepRecording(at date: Date) {
        keepRecording(at: date)
    }
}

public extension AutoStopController.Config {
    /// Builds a live config from `HarcPreferences` (unit: minutes → seconds).
    static func from(
        silenceEnabled: Bool,
        silenceThresholdMinutes: Int,
        hardCapEnabled: Bool,
        hardCapMinutes: Int
    ) -> AutoStopController.Config {
        AutoStopController.Config(
            silenceEnabled: silenceEnabled,
            silenceThresholdSeconds: TimeInterval(silenceThresholdMinutes * 60),
            silenceDbCeiling: -50,
            hardCapEnabled: hardCapEnabled,
            hardCapSeconds: TimeInterval(hardCapMinutes * 60),
            warningSeconds: 60
        )
    }
}
