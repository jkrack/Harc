import Foundation
import Testing
@testable import HarcUI

@Suite("ElapsedFormatter")
struct ElapsedFormatterTests {
    @Test("under an hour reads as m:ss")
    func minutesAndSeconds() {
        #expect(ElapsedFormatter.string(seconds: 0) == "0:00")
        #expect(ElapsedFormatter.string(seconds: 9) == "0:09")
        #expect(ElapsedFormatter.string(seconds: 61) == "1:01")
        #expect(ElapsedFormatter.string(seconds: 3599) == "59:59")
    }

    /// Meeting capture routinely runs past the hour, and "73:24" is not a
    /// duration anyone reads correctly at a glance.
    @Test("an hour promotes to h:mm:ss")
    func hoursPromote() {
        #expect(ElapsedFormatter.string(seconds: 3600) == "1:00:00")
        #expect(ElapsedFormatter.string(seconds: 4404) == "1:13:24")
        #expect(ElapsedFormatter.string(seconds: 36061) == "10:01:01")
    }

    /// A clock that ran backwards would render "-1:-30".
    @Test("a start date in the future clamps to zero")
    func negativeClamps() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 1_060)
        #expect(ElapsedFormatter.string(since: future, now: now) == "0:00")
    }

    @Test("elapsed is measured from the start date")
    func measuresFromStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_000 + 125)
        #expect(ElapsedFormatter.string(since: start, now: now) == "2:05")
    }
}
