import Foundation
import SwiftUI
import Testing
import HarcStore
import HarcPresenceUI
@testable import HarcUI

@Suite("Tide Library presentation")
@MainActor
struct HarcTidePresentationTests {
    @Test func dayOverviewUsesInventoryIncludingZeroLengthRows() async throws {
        let store = try await RecordingStore.inMemory()
        let library = LibraryViewModel(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Recording(wavPath: "/fixture/zero.wav", startedAt: day, endedAt: day)
        let second = Recording(wavPath: "/fixture/short.wav", startedAt: day.addingTimeInterval(2),
                               endedAt: day.addingTimeInterval(2.4))
        let older = Recording(wavPath: "/fixture/older.wav", startedAt: day.addingTimeInterval(-86400))
        library.publishObservedRecordings([second, first, older], totalBytes: 0)
        library.filter = .day(older.startedAt)
        #expect(library.recordings.map(\.wavPath) == [older.wavPath])
        #expect(library.recordings(on: day, calendar: calendar).map(\.wavPath) == [second.wavPath, first.wavPath])
        library.searchText = "no matching title"
        #expect(library.recordings(on: day, calendar: calendar).count == 2)
        #expect(library.recordings(on: day.addingTimeInterval(86400), calendar: calendar).isEmpty)
    }

    @Test func curveRejectsNonfiniteAndOutOfRangeLevelsWithoutOvershoot() {
        let samples: [Float] = [.nan, -.infinity, -2, 0, 1, 8, .infinity, 0.5]
        let curve = HarcTideCurve(samples: samples, size: CGSize(width: 320, height: 100),
                                  baseline: 90, amplitude: 80)
        for step in 0...100 {
            let point = curve.point(at: Double(step) / 100)
            #expect(point.x.isFinite && point.y.isFinite)
            #expect(point.y >= 10 && point.y <= 90)
        }
        #expect(curve.point(at: -1).x == 0)
        #expect(curve.point(at: 2).x == 320)
        #expect(curve.point(at: .nan).x == 0)
    }

    @Test func curveHandlesMissingEnvelopeAndNarrowLayout() {
        let empty = HarcTideCurve(samples: [], size: .zero, baseline: 0, amplitude: 0)
        #expect(empty.path.isEmpty)
        let narrow = HarcTideCurve(samples: [0, 1, 0], size: CGSize(width: 1, height: 20),
                                   baseline: 20, amplitude: 16)
        #expect(narrow.point(at: 0.5).y.isFinite)
        #expect(narrow.point(at: 1).x == 1)
    }
}
