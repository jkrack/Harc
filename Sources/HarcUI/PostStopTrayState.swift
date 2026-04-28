import Foundation
import SwiftUI

/// Drives the post-stop tray inside the slim MenuBarExtra panel.
/// Visible for `visibleDuration` after `show(...)`, then auto-fades.
@MainActor
public final class PostStopTrayState: ObservableObject {
    @Published public private(set) var isVisible: Bool = false
    @Published public private(set) var lastTitle: String? = nil
    @Published public private(set) var lastTranscript: String? = nil

    private let visibleDuration: Duration
    private var fadeTask: Task<Void, Never>? = nil

    public init(visibleDuration: Duration = .seconds(30)) {
        self.visibleDuration = visibleDuration
    }

    public func show(title: String, transcript: String) {
        fadeTask?.cancel()
        lastTitle = title
        lastTranscript = transcript
        isVisible = true
        fadeTask = Task { [weak self, visibleDuration] in
            try? await Task.sleep(for: visibleDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isVisible = false }
        }
    }

    public func dismiss() {
        fadeTask?.cancel()
        isVisible = false
    }
}
