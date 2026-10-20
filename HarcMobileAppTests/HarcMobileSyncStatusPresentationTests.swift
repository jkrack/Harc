import Foundation
import XCTest
@testable import HarcMobile

final class HarcMobileSyncStatusPresentationTests: XCTestCase {
    typealias Status = HarcMobileSyncStatusPresentation

    func testQualificationGateNeverOffersRetryAcrossHostOrTransferStates() {
        for host: Status.Host in [.unpaired, .checking, .connected, .unavailable] {
            for transfer: Status.Transfer in [.idle, .working, .waitingForPairing,
                                              .qualificationRequired, .retryNeeded, .receiptVerified] {
                let status = Status.make(host: host, transfer: transfer, codecQualified: false, pendingCount: 3)
                XCTAssertEqual(status.reason, .qualificationRequired)
                XCTAssertEqual(status.action, .localRecordings)
                XCTAssertEqual(
                    status.detail,
                    "Sending to your Mac isn't turned on in this version of Harc yet. Your recordings are safe here, and you can play or export them anytime."
                )
                XCTAssertEqual(status.pendingCount, 3)
            }
        }
    }

    func testSecurityStopsRequireHostReviewEvenWhenQualificationIsAlsoClosed() {
        for qualified in [false, true] {
            for (host, transfer): (Status.Host, Status.Transfer) in [
                (.repairRequired, .idle), (.connected, .securityBlocked)
            ] {
                let status = Status.make(host: host, transfer: transfer, codecQualified: qualified, pendingCount: 2)
                XCTAssertEqual(status.reason, .securityBlocked)
                XCTAssertEqual(status.action, .hostSettings)
                XCTAssertEqual(status.qualificationNotice == nil, qualified)
            }
        }
    }

    func testUnpairedAndOfflineHaveDifferentReasonsAndReviewConnectionActions() {
        let unpaired = Status.make(host: .unpaired, transfer: .waitingForPairing, codecQualified: true, pendingCount: 1)
        let offline = Status.make(host: .unavailable, transfer: .idle, codecQualified: true, pendingCount: 1)
        XCTAssertEqual(unpaired.reason, .unpaired)
        XCTAssertTrue(unpaired.detail.contains("Pair"))
        XCTAssertEqual(offline.reason, .offline)
        XCTAssertTrue(offline.detail.contains("could not be reached"))
        XCTAssertEqual(unpaired.action, .hostSettings)
        XCTAssertEqual(offline.action, .hostSettings)
    }

    func testRetryIsOnlyOfferedForQualifiedConnectedPendingWork() {
        for transfer: Status.Transfer in [.idle, .retryNeeded] {
            let status = Status.make(host: .connected, transfer: transfer, codecQualified: true, pendingCount: 1)
            XCTAssertEqual(status.action, .retryTransfers)
        }
        let checking = Status.make(host: .checking, transfer: .retryNeeded, codecQualified: true, pendingCount: 1)
        XCTAssertEqual(checking.reason, .checking)
        XCTAssertEqual(checking.action, .none)
    }

    func testEmptyQueueAndHostConnectionNeverInventReceiptSuccess() {
        let idle = Status.make(host: .connected, transfer: .idle, codecQualified: true, pendingCount: 0)
        XCTAssertEqual(idle.reason, .nothingPending)
        XCTAssertFalse(idle.title.contains("verified"))
        let receipt = Status.make(host: .connected, transfer: .receiptVerified, codecQualified: true, pendingCount: 0)
        XCTAssertEqual(receipt.reason, .receiptVerified)
        let morePending = Status.make(host: .connected, transfer: .receiptVerified, codecQualified: true, pendingCount: 2)
        XCTAssertNotEqual(morePending.reason, .receiptVerified)
    }

    func testActiveTransferDoesNotLookCaughtUpDuringQueueCountTransition() {
        let status = Status.make(host: .connected, transfer: .working, codecQualified: true, pendingCount: 0)
        XCTAssertEqual(status.reason, .working)
        XCTAssertEqual(status.action, .none)
    }

    func testPreparingAndNegativePendingCountStayConservative() {
        let status = Status.make(host: .checking, transfer: .preparing, codecQualified: false, pendingCount: -1)
        XCTAssertEqual(status.reason, .preparing)
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.action, .none)
    }

    func testOnlySuccessfulLibraryRefreshExposesMetadataUpdateTime() {
        let date = Date(timeIntervalSince1970: 100)
        let success = HarcMobileSyncLibraryEvidence(.ready(lastUpdated: date))
        XCTAssertEqual(success.verifiedMetadataUpdatedAt, date)
        XCTAssertNil(HarcMobileSyncLibraryEvidence(.ready(lastUpdated: nil)).verifiedMetadataUpdatedAt)
        for state: HarcMobileSyncLibraryEvidence.State in [
            .preparing, .unpaired, .accessNotGranted, .refreshing, .offline, .failed, .cancelled
        ] {
            XCTAssertNil(HarcMobileSyncLibraryEvidence(state).verifiedMetadataUpdatedAt)
        }
    }

    func testLibraryRecoveryDistinguishesAuthorizationFromTransportAndCancellation() {
        for state: HarcMobileSyncLibraryEvidence.State in [.unpaired, .accessNotGranted] {
            XCTAssertEqual(HarcMobileSyncLibraryEvidence(state).action, .hostSettings)
        }
        for state: HarcMobileSyncLibraryEvidence.State in [.offline, .failed, .cancelled] {
            XCTAssertEqual(HarcMobileSyncLibraryEvidence(state).action, .refresh)
        }
        XCTAssertEqual(HarcMobileSyncLibraryEvidence(.refreshing).action, .none)
    }
}
