import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileLiveActivityTests: XCTestCase {
    func testDelayedStopFromEarlierRecordingCannotStopCurrentCapture() {
        defer {
            HarcRecordingActivityActions.captureID = nil
            HarcRecordingActivityActions.stop = nil
        }
        var stopped = false
        HarcRecordingActivityActions.captureID = "current"
        HarcRecordingActivityActions.stop = { stopped = true }
        HarcRecordingActivityActions.stop(captureID: "earlier")
        XCTAssertFalse(stopped)
        HarcRecordingActivityActions.stop(captureID: "current")
        XCTAssertTrue(stopped)
    }

    func testFinishedCaptureIgnoresAnOldStopAction() {
        defer {
            HarcRecordingActivityActions.captureID = nil
            HarcRecordingActivityActions.stop = nil
        }
        var stopped = false
        HarcRecordingActivityActions.captureID = nil
        HarcRecordingActivityActions.stop = { stopped = true }
        HarcRecordingActivityActions.stop(captureID: "finished")
        XCTAssertFalse(stopped)
    }
}
