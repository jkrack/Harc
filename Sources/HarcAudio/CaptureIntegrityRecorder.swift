import Foundation
import HarcCore

/// A bounded in-memory accumulator with one serial persistence worker. No disk
/// I/O runs on a capture callback. The first observation of each category is
/// queued immediately; Stop synchronizes the final counts before publication.
final class CaptureIntegrityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let persistence = DispatchQueue(label: "com.harc.capture-integrity")
    private var report = CaptureIntegrityReport()
    private var writtenFrames: UInt64 = 0
    private var audioURL: URL?
    private let onIssue: (@Sendable (CaptureIntegrityReport) -> Void)?
    private let onPersistenceFailure: (@Sendable (String) -> Void)?

    init(onIssue: (@Sendable (CaptureIntegrityReport) -> Void)?,
         onPersistenceFailure: (@Sendable (String) -> Void)?) {
        self.onIssue = onIssue
        self.onPersistenceFailure = onPersistenceFailure
    }
    func configure(audioURL: URL) { lock.withLock { self.audioURL = audioURL } }
    func wrote(frames: UInt32) { lock.withLock { writtenFrames += UInt64(frames) } }
    var writtenFrameCount: UInt64 { lock.withLock { writtenFrames } }
    func observe(_ source: CaptureIntegrityReport.Source, _ reason: CaptureIntegrityReport.Reason) {
        let observation = lock.withLock { () -> (Bool, CaptureIntegrityReport) in
            let first = report.record(source: source, reason: reason, frameOffset: writtenFrames)
            return (first, report)
        }
        guard observation.0 else { return }
        onIssue?(observation.1)
        persistence.async { [self] in
            do { try persistSnapshot() }
            catch { onPersistenceFailure?("Capture integrity information could not be saved: \(error.localizedDescription)") }
        }
    }
    func snapshot() -> CaptureIntegrityReport { lock.withLock { report } }
    func flush() throws { try persistence.sync { try persistSnapshot() } }
    private func persistSnapshot() throws {
        let (report, url) = lock.withLock { (self.report, audioURL) }
        if report.hasIssues, let url { try report.save(nextTo: url) }
    }
}
