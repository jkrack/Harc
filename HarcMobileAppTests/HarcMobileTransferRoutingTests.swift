import XCTest
import HarcDomain
import HarcTransfer
@testable import HarcMobile

@MainActor
final class HarcMobileTransferRoutingTests: XCTestCase {
    func testDirectOnlyRouteDefersToAnActiveBackgroundUpload() {
        let uploadID = UploadID.random()

        XCTAssertTrue(
            HarcMobileTransferCoordinator.shouldDeferToBackgroundUpload(
                uploadID: uploadID,
                backgroundManagedUploadIDs: [uploadID],
                hasRelayRoute: false
            )
        )
    }

    func testRelayCapableRouteKeepsBackgroundUploadEligibleForRecovery() {
        let uploadID = UploadID.random()

        XCTAssertFalse(
            HarcMobileTransferCoordinator.shouldDeferToBackgroundUpload(
                uploadID: uploadID,
                backgroundManagedUploadIDs: [uploadID],
                hasRelayRoute: true
            )
        )
    }

    func testUnmanagedUploadIsAlwaysEligibleForRetry() {
        XCTAssertFalse(
            HarcMobileTransferCoordinator.shouldDeferToBackgroundUpload(
                uploadID: .random(),
                backgroundManagedUploadIDs: [],
                hasRelayRoute: false
            )
        )
    }
}
