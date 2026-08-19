import Foundation
import Combine

/// User-facing state for moving existing On This Mac recordings through the
/// Desktop Client's local-processing and adopted-Host publication pipeline.
///
/// This deliberately describes the job in product language. The view never
/// needs to expose outboxes, capture sidecars, codecs, receipts, or retries.
@MainActor
public final class LocalLibraryReprocessState: ObservableObject {
    public struct Progress: Equatable, Sendable {
        public let completed: Int
        public let total: Int
        public let currentTitle: String

        public init(completed: Int, total: Int, currentTitle: String) {
            self.completed = completed
            self.total = total
            self.currentTitle = currentTitle
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let readyForHost: Int
        public let alreadyQueued: Int
        public let failed: Int

        public init(readyForHost: Int, alreadyQueued: Int, failed: Int) {
            self.readyForHost = readyForHost
            self.alreadyQueued = alreadyQueued
            self.failed = failed
        }

        public var message: String {
            var parts: [String] = []
            if readyForHost > 0 {
                parts.append("\(readyForHost) ready for Host")
            }
            if alreadyQueued > 0 {
                parts.append("\(alreadyQueued) already queued")
            }
            if failed > 0 {
                parts.append("\(failed) need attention")
            }
            return parts.isEmpty ? "Nothing needed reprocessing." : parts.joined(separator: " · ")
        }
    }

    @Published public private(set) var progress: Progress?
    @Published public private(set) var lastOutcome: Outcome?
    @Published public private(set) var failureMessage: String?

    public init() {}

    public var isRunning: Bool { progress != nil }

    public var statusText: String? {
        if let progress {
            return "Reprocessing \(progress.completed + 1) of \(progress.total): \(progress.currentTitle)"
        }
        return lastOutcome?.message
    }

    public func begin(total: Int) {
        lastOutcome = nil
        failureMessage = nil
        progress = total > 0
            ? Progress(completed: 0, total: total, currentTitle: "Preparing…")
            : nil
    }

    public func advance(completed: Int, total: Int, currentTitle: String) {
        progress = Progress(
            completed: completed,
            total: total,
            currentTitle: currentTitle
        )
    }

    public func finish(_ outcome: Outcome, firstFailure: String?) {
        progress = nil
        lastOutcome = outcome
        failureMessage = firstFailure
    }

    public func clearFailure() {
        failureMessage = nil
    }
}
