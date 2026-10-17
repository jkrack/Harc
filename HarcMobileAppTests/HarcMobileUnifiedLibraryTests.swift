import Foundation
import HarcDomain
import XCTest
@testable import HarcMobile

final class HarcMobileUnifiedLibraryTests: XCTestCase {
    func testExactOriginIdentityLetsHostRowReplaceLocalRow() throws {
        let origin = try origin(deviceByte: 1, recordingByte: 1)
        let local = localRecording(origin: origin, startedAt: date(10))
        let host = try hostRecording(
            origin: origin,
            canonicalByte: 2,
            startedAt: date(10)
        )

        let items = HarcMobileUnifiedLibrary.items(
            local: [local],
            host: [host]
        )

        XCTAssertEqual(items, [.host(host)])
    }

    func testDifferentOriginIdentityNeverGuessesAtDedupe() throws {
        let localOrigin = try origin(deviceByte: 1, recordingByte: 1)
        let hostOrigin = try origin(deviceByte: 2, recordingByte: 1)
        let local = localRecording(origin: localOrigin, startedAt: date(10))
        let host = try hostRecording(
            origin: hostOrigin,
            canonicalByte: 2,
            startedAt: date(10)
        )

        let items = HarcMobileUnifiedLibrary.items(
            local: [local],
            host: [host]
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains(.local(local)))
        XCTAssertTrue(items.contains(.host(host)))
    }

    func testGroupsAreNewestFirstWithTodayAndYesterdayLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(12 * 60 * 60)
        let today = localRecording(
            origin: try origin(deviceByte: 1, recordingByte: 1),
            startedAt: date(11 * 60 * 60)
        )
        let yesterday = localRecording(
            origin: try origin(deviceByte: 1, recordingByte: 2),
            startedAt: date(-(2 * 60 * 60))
        )

        let groups = HarcMobileUnifiedLibrary.groups(
            local: [yesterday, today],
            host: [],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].recordings, [.local(today)])
        XCTAssertEqual(groups[1].recordings, [.local(yesterday)])
    }

    func testAttentionUsesApprovedPriority() {
        XCTAssertEqual(
            HarcMobileLibraryAttention.make(
                securityBlocked: true,
                conflictCount: 2,
                pendingCount: 3,
                libraryIsOffline: true
            ),
            .securityBlocked
        )
        XCTAssertEqual(
            HarcMobileLibraryAttention.make(
                securityBlocked: false,
                conflictCount: 2,
                pendingCount: 3,
                libraryIsOffline: true
            ),
            .conflicts(count: 2)
        )
        XCTAssertEqual(
            HarcMobileLibraryAttention.make(
                securityBlocked: false,
                conflictCount: 0,
                pendingCount: 3,
                libraryIsOffline: true
            ),
            .pending(count: 3)
        )
        XCTAssertEqual(
            HarcMobileLibraryAttention.make(
                securityBlocked: false,
                conflictCount: 0,
                pendingCount: 0,
                libraryIsOffline: true
            ),
            .offlineCache
        )
    }

    func testLocalSearchMatchesGeneratedTitleOnly() throws {
        let recording = localRecording(
            origin: try origin(deviceByte: 1, recordingByte: 1),
            startedAt: date(11 * 60 * 60)
        )
        let title = HarcMobileUnifiedLibrary.localTitle(recording)

        XCTAssertEqual(
            HarcMobileUnifiedLibrary.localTitleMatches(
                [recording],
                query: String(title.suffix(5)),
                excludingHostOrigins: []
            ),
            [recording]
        )
        XCTAssertTrue(
            HarcMobileUnifiedLibrary.localTitleMatches(
                [recording],
                query: "transcript words",
                excludingHostOrigins: []
            ).isEmpty
        )
    }

    private func localRecording(
        origin: OriginRecordingID,
        startedAt: Date
    ) -> HarcMobileLocalRecording {
        HarcMobileLocalRecording(
            id: origin.recordingUUID,
            originID: origin,
            startedAt: startedAt,
            duration: 60,
            masterFileURL: URL(fileURLWithPath: "/tmp/\(origin.recordingUUID).caf"),
            transferState: .localOnly,
            discontinuities: []
        )
    }

    private func hostRecording(
        origin: OriginRecordingID,
        canonicalByte: UInt8,
        startedAt: Date
    ) throws -> LibraryRecordingSummary {
        try LibraryRecordingSummary(
            canonicalID: CanonicalRecordingID(
                UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012x",
                    canonicalByte
                ))!
            ),
            originID: origin,
            revision: .initial,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            title: "Planning",
            processing: .ready
        )
    }

    private func origin(
        deviceByte: UInt8,
        recordingByte: UInt8
    ) throws -> OriginRecordingID {
        OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: deviceByte, count: 32)),
            recordingUUID: UUID(uuidString: String(
                format: "11111111-2222-4333-8444-%012x",
                recordingByte
            ))!
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_006_400 + offset)
    }
}
