import Foundation
import GRDB

/// Virtual day sessions — grouping rows over untouched recordings.
/// A session's audio, transcripts, and timestamps live on its member
/// recordings; the session carries only a title and a combined summary.
public extension RecordingStore {

    // MARK: - Create

    /// Group recordings into a session. Members must be ≥2 existing,
    /// non-deleted recordings on the same local day, none already in a
    /// session. Join rows are ordered by `started_at`. Returns the new
    /// session id.
    @discardableResult
    func createSession(recordingIDs: [Int64], title: String? = nil) async throws -> Int64 {
        guard recordingIDs.count >= 2 else {
            throw StoreError.invalidData("A session needs at least two recordings.")
        }
        let sessionID: Int64 = try await db.write { database in
            let members = try Recording.filter(keys: recordingIDs).fetchAll(database)
            guard members.count == recordingIDs.count else { throw StoreError.notFound }
            guard members.allSatisfy({ $0.deletedAt == nil }) else {
                throw StoreError.invalidData("Deleted recordings can't join a session.")
            }
            let days = Set(members.map { SessionDay.key(for: $0.startedAt) })
            guard days.count == 1, let day = days.first else {
                throw StoreError.invalidData("Session recordings must all be on the same day.")
            }
            let placeholders = recordingIDs.map { _ in "?" }.joined(separator: ", ")
            let taken = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM session_recordings WHERE recording_id IN (\(placeholders))",
                arguments: StatementArguments(recordingIDs)
            ) ?? 0
            guard taken == 0 else {
                throw StoreError.invalidData("A recording can only belong to one session.")
            }

            let session = Session(day: day, title: title)
            try session.insert(database)
            let sid = database.lastInsertedRowID
            let ordered = members.sorted { $0.startedAt < $1.startedAt }
            for (position, member) in ordered.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO session_recordings (session_id, recording_id, position)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [sid, member.id, position]
                )
            }
            return sid
        }
        await reprojectSessionOKF(id: sessionID)
        return sessionID
    }

    // MARK: - Read

    func session(id: Int64) async throws -> Session? {
        try await db.read { database in
            try Session.filter(key: id).fetchOne(database)
        }
    }

    /// All sessions, newest day first, then newest creation first within a day.
    func allSessions() async throws -> [Session] {
        try await db.read { database in
            try Session
                .order(Session.Columns.day.desc, Session.Columns.createdAt.desc)
                .fetchAll(database)
        }
    }

    func sessions(onDay day: Date) async throws -> [Session] {
        let key = SessionDay.key(for: day)
        return try await db.read { database in
            try Session
                .filter(Session.Columns.day == key)
                .order(Session.Columns.createdAt.desc)
                .fetchAll(database)
        }
    }

    /// Every recording id currently in any session. One query — feeds the
    /// combine sheet's "already grouped" filtering without N lookups.
    func sessionMemberRecordingIDs() async throws -> Set<Int64> {
        try await db.read { database in
            Set(try Int64.fetchAll(database, sql: "SELECT recording_id FROM session_recordings"))
        }
    }

    /// The session a recording belongs to, or nil.
    func sessionID(forRecording recordingID: Int64) async throws -> Int64? {
        try await db.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT session_id FROM session_recordings WHERE recording_id = ?",
                arguments: [recordingID]
            )
        }
    }

    /// Active (non-deleted) member recordings in position order.
    func recordings(inSession sessionID: Int64) async throws -> [Recording] {
        try await allMemberRecordings(inSession: sessionID)
            .filter { $0.deletedAt == nil }
    }

    /// All member recordings in position order, soft-deleted included.
    /// The OKF projection anchors its filename on the first row by position,
    /// so the anchor must not shift while a member sits in the trash.
    internal func allMemberRecordings(inSession sessionID: Int64) async throws -> [Recording] {
        try await db.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT recordings.*
                    FROM recordings
                    JOIN session_recordings ON session_recordings.recording_id = recordings.id
                    WHERE session_recordings.session_id = ?
                    ORDER BY session_recordings.position ASC
                    """,
                arguments: [sessionID]
            )
            return try rows.map { try Recording(row: $0) }
        }
    }

    // MARK: - Mutations

    func updateSessionTitle(id: Int64, title: String?) async throws {
        try await db.write { database in
            let count = try Session.filter(key: id).updateAll(
                database,
                [
                    Session.Columns.title.set(to: title),
                    Session.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
        await reprojectSessionOKF(id: id)
    }

    /// Write a generated combined summary onto a session. Clears any prior
    /// non-success status, mirroring `updateSummary` for recordings.
    func updateSessionSummary(
        id: Int64,
        markdown: String,
        actionItemsMarkdown: String,
        modelID: String,
        generatedAt: Date,
        sourceWordCount: Int
    ) async throws {
        let ms = Int64(generatedAt.timeIntervalSince1970 * 1000)
        try await db.write { database in
            let count = try Session.filter(key: id).updateAll(
                database,
                [
                    Session.Columns.summaryMarkdown.set(to: markdown),
                    Session.Columns.actionItemsMarkdown.set(to: actionItemsMarkdown),
                    Session.Columns.summaryModelID.set(to: modelID),
                    Session.Columns.summaryGeneratedAt.set(to: ms),
                    Session.Columns.summarySourceWordCount.set(to: sourceWordCount),
                    Session.Columns.summaryStatusKind.set(to: nil),
                    Session.Columns.summaryStatusMessage.set(to: nil),
                    Session.Columns.summaryStatusUpdatedAt.set(to: nil),
                    Session.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
        await reprojectSessionOKF(id: id)
    }

    func clearSessionSummary(id: Int64) async throws {
        try await db.write { database in
            let count = try Session.filter(key: id).updateAll(
                database,
                [
                    Session.Columns.summaryMarkdown.set(to: nil),
                    Session.Columns.actionItemsMarkdown.set(to: nil),
                    Session.Columns.summaryModelID.set(to: nil),
                    Session.Columns.summaryGeneratedAt.set(to: nil),
                    Session.Columns.summarySourceWordCount.set(to: nil),
                    Session.Columns.summaryStatusKind.set(to: nil),
                    Session.Columns.summaryStatusMessage.set(to: nil),
                    Session.Columns.summaryStatusUpdatedAt.set(to: nil),
                    Session.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
        await reprojectSessionOKF(id: id)
    }

    /// Replace the session's free-form notes (the in-app editor's save
    /// path). Empty or whitespace-only clears the column.
    func updateSessionNotes(id: Int64, markdown: String?) async throws {
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? markdown : nil
        try await db.write { database in
            let count = try Session.filter(key: id).updateAll(
                database,
                [
                    Session.Columns.notesMarkdown.set(to: value),
                    Session.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
        await reprojectSessionOKF(id: id)
    }

    /// Append a block to the session's notes — the agent-safe path,
    /// mirroring `appendNote` for recordings.
    func appendSessionNote(id: Int64, block: String) async throws {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await db.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT notes_markdown FROM sessions WHERE id = ?",
                arguments: [id]
            ) else { throw StoreError.notFound }
            let existing: String? = row["notes_markdown"]
            let combined: String
            if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + trimmed
            } else {
                combined = trimmed
            }
            try database.execute(
                sql: "UPDATE sessions SET notes_markdown = ?, updated_at = ? WHERE id = ?",
                arguments: [combined, Date(), id]
            )
        }
        await reprojectSessionOKF(id: id)
    }

    /// Store the last non-successful session summarization state, mirroring
    /// `updateSummaryStatus` for recordings.
    func updateSessionSummaryStatus(
        id: Int64,
        kind: RecordingSummaryStatusKind,
        message: String,
        updatedAt: Date = Date()
    ) async throws {
        let ms = Int64(updatedAt.timeIntervalSince1970 * 1000)
        try await db.write { database in
            let count = try Session.filter(key: id).updateAll(
                database,
                [
                    Session.Columns.summaryStatusKind.set(to: kind.rawValue),
                    Session.Columns.summaryStatusMessage.set(to: message),
                    Session.Columns.summaryStatusUpdatedAt.set(to: ms),
                    Session.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    // MARK: - Membership changes

    /// Remove a recording from its session. Dissolves the session when
    /// fewer than two active members remain; otherwise reprojects (and
    /// cleans up the old document if the filename anchor moved).
    func removeRecording(fromSession sessionID: Int64, recordingID: Int64) async throws {
        let before = try await allMemberRecordings(inSession: sessionID)
        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM session_recordings WHERE session_id = ? AND recording_id = ?",
                arguments: [sessionID, recordingID]
            )
        }
        let after = try await allMemberRecordings(inSession: sessionID)
        let activeAfter = after.filter { $0.deletedAt == nil }
        if activeAfter.count < 2 {
            try await dissolveSession(id: sessionID, lastKnownMembers: before)
        } else {
            if OKFSessionProjection.markdownURL(members: before)
                != OKFSessionProjection.markdownURL(members: after) {
                OKFSessionProjection.remove(members: before)
            }
            await reprojectSessionOKF(id: sessionID)
        }
    }

    /// Delete (dissolve) a session. Member recordings are untouched.
    func deleteSession(id: Int64) async throws {
        let members = try await allMemberRecordings(inSession: id)
        try await dissolveSession(id: id, lastKnownMembers: members, throwIfMissing: true)
    }

    /// After a member recording is deleted or restored, keep the session
    /// consistent: dissolve when fewer than two active members remain,
    /// otherwise refresh the session document. Best-effort; call sites are
    /// deletion paths where the primary mutation already succeeded.
    func pruneSessionIfNeeded(afterMemberChange recordingID: Int64) async {
        guard let sid = try? await sessionID(forRecording: recordingID) else { return }
        let members = (try? await allMemberRecordings(inSession: sid)) ?? []
        let active = members.filter { $0.deletedAt == nil }
        if active.count < 2 {
            try? await dissolveSession(id: sid, lastKnownMembers: members)
        } else {
            await reprojectSessionOKF(id: sid)
        }
    }

    private func dissolveSession(
        id: Int64,
        lastKnownMembers: [Recording],
        throwIfMissing: Bool = false
    ) async throws {
        try await db.write { database in
            let count = try Session.filter(key: id).deleteAll(database)
            if throwIfMissing, count == 0 { throw StoreError.notFound }
        }
        OKFSessionProjection.remove(members: lastKnownMembers)
    }

    // MARK: - Projection

    /// Regenerate the session's `session-*.md` from the DB row. Best-effort,
    /// like `reprojectOKF` for recordings.
    internal func reprojectSessionOKF(id: Int64) async {
        guard let session = try? await self.session(id: id) else { return }
        let members = (try? await allMemberRecordings(inSession: id)) ?? []
        guard !members.isEmpty else { return }
        OKFSessionProjection.write(session: session, members: members)
    }

    // MARK: - Observation

    /// AsyncStream re-emitting all sessions (newest day first) on any change
    /// to `sessions` or `session_recordings`.
    nonisolated func observeSessions() -> AsyncStream<[Session]> {
        let (stream, cont) = AsyncStream<[Session]>.makeStream()
        let obs = ValueObservation.tracking { database -> [Session] in
            try Session
                .order(Session.Columns.day.desc, Session.Columns.createdAt.desc)
                .fetchAll(database)
        }

        nonisolated(unsafe) let cancellable = obs.start(
            in: dbReader,
            onError: { _ in cont.finish() },
            onChange: { value in cont.yield(value) }
        )

        cont.onTermination = { _ in cancellable.cancel() }
        return stream
    }

    /// AsyncStream of sidebar-ready session rows: session + active member
    /// count + summed duration. Tracks `sessions`, `session_recordings`, and
    /// the member rows, so a member edit refreshes the overview too.
    nonisolated func observeSessionOverviews() -> AsyncStream<[SessionOverview]> {
        let (stream, cont) = AsyncStream<[SessionOverview]>.makeStream()
        let obs = ValueObservation.tracking { database -> [SessionOverview] in
            try Self.fetchSessionOverviews(database)
        }

        nonisolated(unsafe) let cancellable = obs.start(
            in: dbReader,
            onError: { _ in cont.finish() },
            onChange: { value in cont.yield(value) }
        )

        cont.onTermination = { _ in cancellable.cancel() }
        return stream
    }

    /// One-shot snapshot of the same rows `observeSessionOverviews` streams.
    /// Used to refresh after an external (cross-process) change, which the
    /// observation cannot see.
    func sessionOverviews() async throws -> [SessionOverview] {
        try await db.read { database in
            try Self.fetchSessionOverviews(database)
        }
    }

    internal static func fetchSessionOverviews(_ database: Database) throws -> [SessionOverview] {
        let sessions = try Session
            .order(Session.Columns.day.desc, Session.Columns.createdAt.desc)
            .fetchAll(database)
        return try sessions.map { session in
            guard let sid = session.id else {
                return SessionOverview(session: session, memberIDs: [], totalSeconds: 0)
            }
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT recordings.id, recordings.started_at, recordings.ended_at
                    FROM recordings
                    JOIN session_recordings ON session_recordings.recording_id = recordings.id
                    WHERE session_recordings.session_id = ?
                      AND recordings.deleted_at IS NULL
                    ORDER BY session_recordings.position ASC
                    """,
                arguments: [sid]
            )
            let totals = rows.reduce(0.0) { sum, row in
                guard let start: Date = row["started_at"],
                      let end: Date = row["ended_at"] else { return sum }
                return sum + end.timeIntervalSince(start)
            }
            return SessionOverview(
                session: session,
                memberIDs: rows.compactMap { $0["id"] },
                totalSeconds: totals
            )
        }
    }
}

/// One sidebar row's worth of session facts: the row itself plus active
/// member ids and total recorded time.
public struct SessionOverview: Sendable, Equatable, Identifiable {
    public let session: Session
    public let memberIDs: [Int64]
    public let totalSeconds: Double

    public var id: Int64 { session.id ?? -1 }

    public init(session: Session, memberIDs: [Int64], totalSeconds: Double) {
        self.session = session
        self.memberIDs = memberIDs
        self.totalSeconds = totalSeconds
    }
}
