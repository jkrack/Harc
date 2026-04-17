import Testing
@testable import HarcCore

@Suite("Version")
struct VersionTests {
    @Test("current is SemVer")
    func currentIsSemVer() {
        let parts = HarcVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
