import Foundation
import HarcDomain

enum HarcMobileUnifiedLibraryItem: Identifiable, Equatable {
    enum ID: Hashable {
        case local(OriginRecordingID)
        case host(CanonicalRecordingID)
    }

    case local(HarcMobileLocalRecording)
    case host(LibraryRecordingSummary)

    var id: ID {
        switch self {
        case .local(let recording): .local(recording.originID)
        case .host(let recording): .host(recording.canonicalID)
        }
    }

    var startedAt: Date {
        switch self {
        case .local(let recording): recording.startedAt
        case .host(let recording): recording.startedAt
        }
    }
}

struct HarcMobileUnifiedLibraryGroup: Identifiable, Equatable {
    let day: Date
    let title: String
    let recordings: [HarcMobileUnifiedLibraryItem]

    var id: Date { day }
}

enum HarcMobileUnifiedLibrary {
    static func items(
        local: [HarcMobileLocalRecording],
        host: [LibraryRecordingSummary]
    ) -> [HarcMobileUnifiedLibraryItem] {
        let hostOrigins = Set(host.compactMap(\.originID))
        let unmatchedLocal = local.filter {
            !hostOrigins.contains($0.originID)
        }
        return (
            host.map(HarcMobileUnifiedLibraryItem.host)
                + unmatchedLocal.map(HarcMobileUnifiedLibraryItem.local)
        ).sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return String(describing: lhs.id) < String(describing: rhs.id)
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    static func groups(
        local: [HarcMobileLocalRecording],
        host: [LibraryRecordingSummary],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HarcMobileUnifiedLibraryGroup] {
        let grouped = Dictionary(grouping: items(local: local, host: host)) {
            calendar.startOfDay(for: $0.startedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            HarcMobileUnifiedLibraryGroup(
                day: day,
                title: dayTitle(day, now: now, calendar: calendar),
                recordings: grouped[day] ?? []
            )
        }
    }

    static func localTitleMatches(
        _ local: [HarcMobileLocalRecording],
        query rawQuery: String,
        excludingHostOrigins: Set<OriginRecordingID>
    ) -> [HarcMobileLocalRecording] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return local.filter { recording in
            !excludingHostOrigins.contains(recording.originID)
                && localTitle(recording).localizedCaseInsensitiveContains(query)
        }
    }

    static func localTitle(_ recording: HarcMobileLocalRecording) -> String {
        "Recording " + recording.startedAt.formatted(
            date: .omitted,
            time: .shortened
        )
    }

    private static func dayTitle(
        _ day: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month().day())
    }
}

enum HarcMobileLibraryAttention: Equatable {
    case securityBlocked
    case conflicts(count: Int)
    case pending(count: Int)
    case offlineCache

    static func make(
        securityBlocked: Bool,
        conflictCount: Int,
        pendingCount: Int,
        libraryIsOffline: Bool
    ) -> Self? {
        if securityBlocked { return .securityBlocked }
        if conflictCount > 0 { return .conflicts(count: conflictCount) }
        if pendingCount > 0 { return .pending(count: pendingCount) }
        if libraryIsOffline { return .offlineCache }
        return nil
    }

    func title(macName: String) -> String {
        switch self {
        case .securityBlocked:
            "Sending needs your attention"
        case .conflicts(let count):
            "\(count) Library conflict\(count == 1 ? "" : "s") to review"
        case .pending(let count):
            "\(count) recording\(count == 1 ? "" : "s") waiting to send to \(macName)"
        case .offlineCache:
            "Showing your saved Library while \(macName) is offline"
        }
    }

    var isSecurityBlocked: Bool {
        if case .securityBlocked = self { return true }
        return false
    }
}
