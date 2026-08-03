import Foundation
import SwiftUI

public struct StopOutcome: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case savedSafely
        case transcriptPending
        case summaryQueued
        case speakerIDPending
        case savedWithWarnings
        case recoveryNeeded
    }

    public var kind: Kind
    public var title: String
    public var detail: String

    public init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public static func savedSafely(title: String, wavPath: String?) -> StopOutcome {
        let detail = wavPath.map { "Saved to \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? title
        return StopOutcome(kind: .savedSafely, title: "Saved safely", detail: detail)
    }

    public static func recoveryNeeded(detail: String) -> StopOutcome {
        StopOutcome(kind: .recoveryNeeded, title: "Audio capture stopped, recovery needed", detail: detail)
    }
}

/// Drives the post-stop tray inside the slim MenuBarExtra panel.
/// Visible for `visibleDuration` after `show(...)`, then auto-fades.
@MainActor
public final class PostStopTrayState: ObservableObject {
    @Published public private(set) var isVisible: Bool = false
    @Published public private(set) var lastTitle: String? = nil
    @Published public private(set) var lastTranscript: String? = nil
    @Published public private(set) var lastRecordingID: Int64? = nil
    @Published public private(set) var lastWavPath: String? = nil
    @Published public private(set) var lastOutcome: StopOutcome? = nil

    private let visibleDuration: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var fadeTask: Task<Void, Never>? = nil

    public convenience init(visibleDuration: Duration = .seconds(30)) {
        self.init(
            visibleDuration: visibleDuration,
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }

    init(
        visibleDuration: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.visibleDuration = visibleDuration
        self.sleep = sleep
    }

    public func show(
        title: String,
        transcript: String,
        recordingID: Int64? = nil,
        wavPath: String? = nil,
        outcome: StopOutcome? = nil
    ) {
        fadeTask?.cancel()
        lastTitle = title
        lastTranscript = transcript
        lastRecordingID = recordingID
        lastWavPath = wavPath
        lastOutcome = outcome ?? .savedSafely(title: title, wavPath: wavPath)
        isVisible = true
        fadeTask = Task { [weak self, visibleDuration, sleep] in
            try? await sleep(visibleDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isVisible = false }
        }
    }

    public func showOutcome(title: String, outcome: StopOutcome) {
        show(title: title, transcript: "", recordingID: nil, wavPath: nil, outcome: outcome)
    }

    public func dismiss() {
        fadeTask?.cancel()
        isVisible = false
    }
}
