import Foundation
import Testing
@testable import HarcCore

@Suite("Capture integrity report")
struct CaptureIntegrityReportTests {
    @Test("repeated failures remain bounded and retain the first detection offset")
    func boundedObservations() throws {
        var report = CaptureIntegrityReport()
        for frame in 0..<1000 {
            report.record(source: .systemAudio, reason: .bufferOverrun, frameOffset: UInt64(frame))
        }
        #expect(report.issues.count == 1)
        #expect(report.issues.first?.frameOffset == 0)
        #expect(report.issues.first?.occurrences == 1000)
        #expect(try JSONDecoder().decode(CaptureIntegrityReport.self, from: JSONEncoder().encode(report)) == report)
    }

    @Test("only a missing sidecar is treated as a legacy capture without recorded issues")
    func loadFailureIsNotEmptyEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("capture.wav")
        #expect(try CaptureIntegrityReport.load(nextTo: audio).issues.isEmpty)
        try Data("invalid".utf8).write(to: CaptureIntegrityReport.sidecarURL(for: audio))
        #expect(throws: (any Error).self) { try CaptureIntegrityReport.load(nextTo: audio) }
    }
}
