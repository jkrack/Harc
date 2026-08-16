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

    func testFailedProbePreservesTheLastAuthenticatedTimestamp() async {
        let priorVerification = Date(timeIntervalSinceReferenceDate: 100)
        let coordinator = HarcMobileHostHealthCoordinator(
            hasActiveAdoption: true,
            lastVerifiedAt: priorVerification
        ) {
            throw TestError.unreachable
        }

        await coordinator.refresh()

        XCTAssertEqual(coordinator.lastVerifiedAt, priorVerification)
        guard case .unavailable = coordinator.status else {
            return XCTFail("Expected an unavailable Host")
        }
    }

    func testSuccessfulProbePersistsTheAuthenticatedTimestamp() async {
        var persisted: Date?
        let coordinator = HarcMobileHostHealthCoordinator(
            hasActiveAdoption: true,
            persistLastVerifiedAt: { persisted = $0 }
        ) {}

        await coordinator.refresh()

        XCTAssertEqual(persisted, coordinator.lastVerifiedAt)
        XCTAssertNotNil(persisted)
    }

    func testAuthenticatedProbePersistsActualHostDisplayName() async {
        var persistedName: String?
        let coordinator = HarcMobileHostHealthCoordinator(
            hostIdentityProbe: { "Studio Mac mini" },
            hasActiveAdoption: true,
            hostDisplayName: "Previous Host",
            persistHostDisplayName: { persistedName = $0 }
        )

        await coordinator.refresh()

        XCTAssertEqual(coordinator.hostDisplayName, "Studio Mac mini")
        XCTAssertEqual(persistedName, "Studio Mac mini")
    }

    private enum TestError: Error {
        case unreachable
    }
}
