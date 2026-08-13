import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileHostHealthCoordinatorTests: XCTestCase {
    func testSuccessfulAuthenticatedProbeReportsDesktopConnected() async {
        var probeCount = 0
        let coordinator = HarcMobileHostHealthCoordinator(
            hasActiveAdoption: true
        ) {
            probeCount += 1
        }

        await coordinator.refresh()

        XCTAssertEqual(probeCount, 1)
        guard case .connected = coordinator.status else {
            return XCTFail("Expected a verified Host connection")
        }
        XCTAssertEqual(coordinator.status.title, "Desktop connected")
        XCTAssertFalse(coordinator.isChecking)
    }

    func testFailedAuthenticatedProbeReportsDesktopUnavailable() async {
        let coordinator = HarcMobileHostHealthCoordinator(
            hasActiveAdoption: true
        ) {
            throw TestError.unreachable
        }

        await coordinator.refresh()

        guard case .unavailable = coordinator.status else {
            return XCTFail("Expected an unavailable Host")
        }
        XCTAssertEqual(coordinator.status.title, "Desktop unavailable")
        XCTAssertTrue(
            coordinator.status.accessibilityValue.contains(
                "Local recording remains available"
            )
        )
    }

    func testUnpairedClientBecomesCheckingBeforeItsFirstProbe() {
        let coordinator = HarcMobileHostHealthCoordinator(
            hasActiveAdoption: false
        ) {}

        XCTAssertEqual(coordinator.status, .unpaired)
        XCTAssertEqual(coordinator.status.title, "Desktop not paired")
    }

    private enum TestError: Error {
        case unreachable
    }
}
