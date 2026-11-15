import Foundation
import HarcDomain
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileAudioSummaryRefreshTests: XCTestCase {
    func testIdleAndFailedDescriptorsAcceptOnlyNewerMatchingIdentity() throws {
        let current = try summary(revision: 2)
        let newer = try summary(like: current, revision: 3)
        for state in [HarcMobileRecordingAudioController.State.idle, .failed("Retry")] {
            XCTAssertTrue(canUpdate(current, newer, state: state))
            XCTAssertFalse(canUpdate(current, current, state: state))
            XCTAssertFalse(canUpdate(current, try summary(like: current, revision: 1), state: state))
            XCTAssertFalse(canUpdate(current, try summary(revision: 4), state: state))
            let changedOrigin = try LibraryRecordingSummary(
                canonicalID: current.canonicalID, originID: nil,
                revision: EntityRevision(4), startedAt: current.startedAt
            )
            XCTAssertFalse(canUpdate(current, changedOrigin, state: state))
        }
    }

    func testDownloadingPlayingAndPausedDescriptorsStayBoundToOriginal() throws {
        let current = try summary(revision: 1)
        let newer = try summary(like: current, revision: 2)
        for state in [HarcMobileRecordingAudioController.State.downloading, .playing, .paused] {
            XCTAssertFalse(canUpdate(current, newer, state: state))
        }
        // Also reject an idle/failed state while any player is still retained.
        for state in [HarcMobileRecordingAudioController.State.idle, .failed("Retry")] {
            XCTAssertFalse(HarcMobileRecordingAudioController.canUpdateSummary(
                current: current, new: newer, state: state, hasPlayer: true
            ))
        }
    }

    private func canUpdate(
        _ current: LibraryRecordingSummary, _ new: LibraryRecordingSummary,
        state: HarcMobileRecordingAudioController.State
    ) -> Bool {
        HarcMobileRecordingAudioController.canUpdateSummary(
            current: current, new: new, state: state, hasPlayer: false
        )
    }

    private func summary(like existing: LibraryRecordingSummary? = nil, revision: UInt64) throws
        -> LibraryRecordingSummary {
        try LibraryRecordingSummary(
            canonicalID: existing?.canonicalID ?? .random(),
            originID: existing?.originID ?? OriginRecordingID(
                deviceID: DeviceID(Data(repeating: 0x19, count: 32)), recordingUUID: UUID()
            ),
            revision: EntityRevision(revision),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
