import Foundation
import Combine

/// Observable state for the library's import banner. One import runs at a
/// time; additional picked/dropped files wait in `queuedCount`.
@MainActor
public final class MediaImportState: ObservableObject {
    public struct Job: Equatable {
        public var filename: String
        public var phaseText: String
        public var fraction: Double

        public init(filename: String, phaseText: String, fraction: Double) {
            self.filename = filename
            self.phaseText = phaseText
            self.fraction = fraction
        }
    }

    @Published public private(set) var current: Job?
    @Published public private(set) var queuedCount: Int = 0
    /// Most recent failure, shown until dismissed or the next import starts.
    @Published public private(set) var lastError: String?
    /// Filename of the most recently completed import — drives a brief
    /// "Imported <file>" confirmation in the banner.
    @Published public private(set) var lastCompletedFilename: String?

    public init() {}

    public var isActive: Bool { current != nil || queuedCount > 0 }

    public func begin(filename: String, queued: Int) {
        lastError = nil
        lastCompletedFilename = nil
        current = Job(filename: filename, phaseText: "Preparing", fraction: 0)
        queuedCount = queued
    }

    public func update(phaseText: String, fraction: Double) {
        guard var job = current else { return }
        job.phaseText = phaseText
        job.fraction = min(1, max(job.fraction, fraction))
        current = job
    }

    public func finish() {
        lastCompletedFilename = current?.filename
        current = nil
    }

    public func fail(message: String) {
        lastError = message
        current = nil
    }

    public func allDone() {
        queuedCount = 0
    }

    /// The user cancelled the batch — clear everything without an error or
    /// a completion banner.
    public func cancelAll() {
        current = nil
        queuedCount = 0
        lastError = nil
        lastCompletedFilename = nil
    }

    public func dismissError() {
        lastError = nil
    }

    public func dismissCompleted() {
        lastCompletedFilename = nil
    }
}
