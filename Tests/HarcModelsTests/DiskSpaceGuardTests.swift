import XCTest
@testable import HarcModels

final class DiskSpaceGuardTests: XCTestCase {

    func test_check_passesWhenFreeExceedsRequiredPlusHeadroom() {
        // freeBytes defaults to the real volume; we test the pure arithmetic
        // via a stand-in by calling into the struct's API with a writable
        // temp URL. Any real volume has way more than 1024 bytes.
        let guardian = DiskSpaceGuard()
        let tmp = FileManager.default.temporaryDirectory
        let check = guardian.check(requiredBytes: 1024, at: tmp)
        XCTAssertTrue(check.hasSpace)
        XCTAssertEqual(check.required, 1024)
        XCTAssertEqual(check.withHeadroom, Int64(Double(1024) * 1.1))
    }

    func test_check_failsWhenHeadroomExceedsFree() {
        // Ask for more bytes than the temp volume could possibly have —
        // guaranteed on any realistic disk.
        let guardian = DiskSpaceGuard()
        let tmp = FileManager.default.temporaryDirectory
        let check = guardian.check(requiredBytes: Int64.max / 2, at: tmp)
        XCTAssertFalse(check.hasSpace)
    }

    func test_headroomIsApplied() {
        let guardian = DiskSpaceGuard(headroom: 0.5)
        let check = guardian.check(requiredBytes: 1_000_000,
                                   at: FileManager.default.temporaryDirectory)
        XCTAssertEqual(check.withHeadroom, 1_500_000)
    }
}
