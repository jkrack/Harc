import Testing
import Foundation
import HarcUI

@Suite("PasteDenyList")
struct PasteDenyListTests {
    @Test("seed contains the critical bundle IDs")
    func seedContainsCriticalIDs() {
        let expected: Set<String> = [
            "com.apple.loginwindow",
            "com.agilebits.onepassword8",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.apple.finder",
            "com.tinyspeck.slackmacgap",
        ]
        #expect(expected.isSubset(of: PasteDenyList.bundleIDs))
    }

    @Test("isDenied — nil returns false")
    func isDeniedNil() {
        #expect(PasteDenyList.isDenied(nil) == false)
    }

    @Test("isDenied — unknown bundle returns false")
    func isDeniedUnknown() {
        #expect(PasteDenyList.isDenied("com.unknown.app") == false)
    }

    @Test("isDenied — known bundle returns true")
    func isDeniedKnown() {
        #expect(PasteDenyList.isDenied("com.apple.finder") == true)
        #expect(PasteDenyList.isDenied("com.agilebits.onepassword7") == true)
    }
}
