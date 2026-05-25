import Foundation
import Testing
import HarcExport
import HarcStore
@testable import HarcUI

@Suite("Customer experience E2E fixtures")
@MainActor
struct CustomerExperienceE2ETests {
    @Test("menu recording flow saves sample data, appears in Library, searches, and exports")
    func menuRecordingFlowSavesAppearsSearchesAndExports() async throws {
        let fixture = try await CustomerExperienceFixture.make()
        defer { fixture.cleanup() }

        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        let startedAt = CustomerExperienceFixture.date(year: 2026, month: 5, day: 18, hour: 9, minute: 0)
        bridge.recordingState.markStarted(at: startedAt)
        bridge.setActiveCaptureStatus(ActiveCaptureStatus(
            sourceState: .checking,
            cachePath: fixture.cacheURL.path,
            destinationPath: fixture.recordingsURL.path,
            startedAt: startedAt
        ))
        bridge.updateActiveCaptureSource(.micAndSystemAudio)
        bridge.recordingState.appendPreview("Amy: pricing risk is still open.")
        bridge.markActiveTranscriptUpdate(at: startedAt.addingTimeInterval(12))

        #expect(bridge.recordingState.isRecording)
        #expect(bridge.activeCaptureStatus?.sourceState == .micAndSystemAudio)
        #expect(bridge.activeCaptureStatus?.transcriptAgeText(referenceDate: startedAt.addingTimeInterval(20)) == "Transcript updated 8s ago")

        let created = try fixture.writeCompletedRecording(
            stem: "09-00-00",
            title: "Customer Renewal Call",
            transcript: "Amy: pricing risk is still open. Jason: send the renewal plan by Friday.",
            speakerNames: [0: "Amy", 1: "Jason"],
            tags: ["customer", "renewal"],
            summary: "The renewal is healthy, but pricing risk needs follow-up.",
            actionItems: "- [ ] Jason: send the renewal plan by Friday"
        )
        let inserted = try await RecordingIngestor(baseDirectory: fixture.recordingsURL, store: fixture.store).ingestAll()
        #expect(inserted == 1)

        var recording = try #require(try await fixture.store.fetchAll().first {
            URL(fileURLWithPath: $0.wavPath).lastPathComponent == created.wavURL.lastPathComponent
        })
        recording.title = created.title
        recording.speakerNames = created.speakerNames
        recording.tags = created.tags
        recording = try await fixture.store.upsert(recording)
        try await fixture.store.updateSummary(
            id: recording.id!,
            markdown: created.summary,
            actionItemsMarkdown: created.actionItems,
            modelID: "fixture-summary-model",
            generatedAt: startedAt.addingTimeInterval(90),
            sourceWordCount: 13
        )

        bridge.recordingState.markStopped(
            wavURL: URL(fileURLWithPath: recording.wavPath),
            txtURL: recording.txtPath.map(URL.init(fileURLWithPath:)),
            jsonURL: recording.jsonPath.map(URL.init(fileURLWithPath:))
        )
        bridge.trayState.show(
            title: recording.displayTitle,
            transcript: recording.transcriptText ?? "",
            recordingID: recording.id,
            wavPath: recording.wavPath
        )
        bridge.setActiveCaptureStatus(nil)

        #expect(bridge.recordingState.isRecording == false)
        #expect(bridge.trayState.lastOutcome?.kind == .savedSafely)
        #expect(bridge.trayState.lastRecordingID == recording.id)

        let library = LibraryViewModel(store: fixture.store)
        library.start()
        defer { library.stop() }
        #expect(await waitForCustomerExperienceState { library.recordings.map(\.wavPath).contains(recording.wavPath) })

        library.searchText = "pricing renewal"
        try await Task.sleep(for: .milliseconds(350))
        #expect(library.hits.first?.recording.wavPath == recording.wavPath)
        #expect(library.hits.first?.snippet.localizedCaseInsensitiveContains("pricing") == true)

        let prompt = ExportService.promptString(for: try #require(try await fixture.store.fetch(id: recording.id!)))
        #expect(prompt.contains("Customer Renewal Call"))
        #expect(prompt.contains("## Summary"))
        #expect(prompt.contains("The renewal is healthy"))
        #expect(prompt.contains("Jason: send the renewal plan"))
    }

    @Test("note taking covers standalone, linked, active-recording, conflict, and recovery states")
    func noteTakingCoversAllRecordingVariations() async throws {
        let fixture = try await CustomerExperienceFixture.make()
        defer { fixture.cleanup() }

        let recording = try await fixture.seedRecording(
            stem: "10-15-30",
            title: "Roadmap Working Session",
            transcript: "Michelle: lock the beta date. Amy: create the launch note.",
            pinned: false
        )

        var standalone = try await fixture.noteStore.create(
            title: "Launch scratchpad",
            body: "Raw launch notes",
            recordings: []
        )
        standalone.tags = ["launch", "customer"]
        standalone.people = ["Michelle"]
        standalone = try await fixture.noteStore.update(standalone)

        let linked = try await fixture.noteStore.create(title: "Roadmap", body: "## Agenda\n\nBeta date")
        let linkedAfterStop = try await fixture.noteStore.link(
            recording: recording,
            toNoteID: linked.id,
            transcriptText: recording.transcriptText
        )

        #expect(linkedAfterStop.recordings == ["recording:\(recording.id!)"])
        #expect(linkedAfterStop.body.contains("## Recording: [[Roadmap Working Session]]"))
        #expect(linkedAfterStop.body.contains("Michelle: lock the beta date"))
        #expect((try await fixture.noteStore.search(query: "launch customer")).map(\.id) == [standalone.id])

        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        #expect(NoteRecordingToolbarState.resolve(isRecording: false, activeNoteID: nil, currentNoteID: linked.id) == .idle)

        bridge.recordingState.markStarted(at: recording.startedAt)
        bridge.setActiveNoteRecordingID(linked.id)
        #expect(NoteRecordingToolbarState.resolve(
            isRecording: bridge.recordingState.isRecording,
            activeNoteID: bridge.activeNoteRecordingID,
            currentNoteID: linked.id
        ) == .recordingIntoThisNote)

        bridge.showNoteRecordingLinked(
            noteID: linked.id,
            recordingTitle: recording.displayTitle,
            recordingID: recording.id,
            wavPath: recording.wavPath
        )
        #expect(bridge.noteRecordingLinkFeedback?.status == .linked)
        #expect(bridge.noteRecordingLinkFeedback?.canOpenRecording == true)

        bridge.setActiveNoteRecordingID("other-note")
        #expect(NoteRecordingToolbarState.resolve(
            isRecording: bridge.recordingState.isRecording,
            activeNoteID: bridge.activeNoteRecordingID,
            currentNoteID: linked.id
        ) == .recordingIntoAnotherNote)
        bridge.showNoteRecordingConflict(requestedNoteID: linked.id)
        #expect(bridge.noteRecordingConflict?.message.contains("Another note owns") == true)

        bridge.setActiveNoteRecordingID(nil)
        #expect(NoteRecordingToolbarState.resolve(
            isRecording: bridge.recordingState.isRecording,
            activeNoteID: bridge.activeNoteRecordingID,
            currentNoteID: linked.id
        ) == .generalRecording)

        bridge.showNoteRecordingMissingSavedID(
            noteID: linked.id,
            recordingTitle: "Unsaved cache recording",
            wavPath: fixture.cacheURL.appendingPathComponent("unsaved.wav").path
        )
        #expect(bridge.noteRecordingLinkFeedback?.isRecoveryNeeded == true)
        #expect(bridge.noteRecordingLinkFeedback?.canRevealFile == true)

        bridge.showNoteRecordingLinkFailed(
            noteID: linked.id,
            recordingTitle: recording.displayTitle,
            recordingID: recording.id,
            wavPath: recording.wavPath,
            errorDescription: "Note file moved during save"
        )
        #expect(bridge.noteRecordingLinkFeedback?.message.contains("Note file moved during save") == true)

        try await fixture.noteStore.archive(id: standalone.id)
        #expect(try await fixture.noteStore.search(query: "launch customer") == [])
        #expect(try await fixture.noteStore.fetchAll(includeArchived: true).contains { $0.id == standalone.id && $0.archived })
    }

    @Test("Library customer actions cover filters, calendar, pin, rename, delete, and context")
    func libraryCustomerActionsCoverCoreVariations() async throws {
        let fixture = try await CustomerExperienceFixture.make()
        defer { fixture.cleanup() }
        let calendar = Calendar.current
        let todayDate = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date()
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: todayDate) ?? todayDate.addingTimeInterval(-86_400)
        let lastWeekDate = calendar.date(byAdding: .day, value: -10, to: todayDate) ?? todayDate.addingTimeInterval(-864_000)

        let today = try await fixture.seedRecording(
            stem: "11-00-00",
            title: "Today Customer Call",
            transcript: "Sara mentioned onboarding risk and customer expansion.",
            pinned: false,
            startedAt: todayDate
        )
        let yesterday = try await fixture.seedRecording(
            stem: "16-30-00",
            title: "Yesterday Hiring Sync",
            transcript: "Neal reviewed hiring plan and interview loops.",
            pinned: true,
            startedAt: yesterdayDate
        )
        let lastWeek = try await fixture.seedRecording(
            stem: "08-45-00",
            title: "Last Week Support Review",
            transcript: "Support escalations are trending down.",
            pinned: false,
            startedAt: lastWeekDate
        )
        var note = try await fixture.noteStore.create(title: "Onboarding note", body: "Sara owns onboarding follow-up.")
        note.tags = ["onboarding"]
        note = try await fixture.noteStore.update(note)
        _ = note

        let library = LibraryViewModel(store: fixture.store)
        library.start()
        defer { library.stop() }
        #expect(await waitForCustomerExperienceState { library.recordings.count == 3 })
        #expect(library.recordings.first?.id == yesterday.id, "Pinned recording should be first even when older")

        library.filter = .today
        #expect(library.recordings.map(\.id) == [today.id])

        library.filter = .yesterday
        #expect(library.recordings.map(\.id) == [yesterday.id])

        library.filter = .thisWeek
        let expectedThisWeekIDs = [today, yesterday, lastWeek]
            .filter { LibraryFilter.thisWeek.matches($0) }
            .compactMap(\.id)
        #expect(Set(library.recordings.compactMap(\.id)) == Set(expectedThisWeekIDs))

        library.filter = .day(lastWeek.startedAt)
        #expect(library.recordings.map(\.id) == [lastWeek.id])

        try await library.rename(id: today.id!, title: "Renamed Customer Call")
        #expect(await waitForCustomerExperienceState {
            library.filter = .all
            return library.recordings.first(where: { $0.id == today.id })?.title == "Renamed Customer Call"
        })

        let renamed = try #require(try await fixture.store.fetch(id: today.id!))
        try await library.togglePin(id: renamed.id!, currentlyPinned: renamed.pinned)
        #expect(await waitForCustomerExperienceState {
            library.recordings.first(where: { $0.id == today.id })?.pinned == true
        })

        let markdown = try await library.contextMarkdown(
            for: "onboarding customer",
            noteStore: fixture.noteStore
        )
        #expect(markdown.contains("# Context: onboarding customer"))
        #expect(markdown.contains("Today Customer Call") || markdown.contains("Renamed Customer Call"))
        #expect(markdown.contains("Onboarding note"))

        try await library.delete(id: yesterday.id!)
        #expect(await waitForCustomerExperienceState {
            !library.recordings.map(\.id).contains(yesterday.id)
        })
        #expect(try await fixture.store.fetch(id: yesterday.id!)?.deletedAt != nil)
    }

    @Test("recovery customer flow scans cache, publishes inbox state, recovers, and updates tray")
    func recoveryCustomerFlowScansPublishesAndRecovers() async throws {
        let fixture = try await CustomerExperienceFixture.make()
        defer { fixture.cleanup() }

        let cacheWAV = fixture.cacheURL.appendingPathComponent("interrupted.wav")
        try CustomerExperienceFixture.writeRecoverableWAV(to: cacheWAV)
        let queueURL = fixture.rootURL.appendingPathComponent("recovery.json")
        let queue = RecoveryQueue(fileURL: queueURL, store: fixture.store)
        try await queue.scanCache(cacheDirectory: fixture.cacheURL, destinationDirectory: fixture.recordingsURL)

        let pending = try await queue.fetchAll()
        #expect(pending.count == 1)
        #expect(pending[0].kind == .interruptedWAV)
        #expect(pending[0].status == .pending)

        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        bridge.setRecoveryArtifacts(pending)
        bridge.showStopRecovery(StopRecoveryInfo(
            title: "Finalization timed out",
            message: "A cache WAV is available for recovery.",
            cacheDirectoryPath: fixture.cacheURL.path
        ))
        bridge.trayState.showOutcome(
            title: "Recovery needed",
            outcome: .recoveryNeeded(detail: "Audio capture stopped before finalization completed.")
        )

        #expect(RecoveryInboxModel.unresolvedCount(in: bridge.recoveryArtifacts) == 1)
        #expect(bridge.stopRecovery?.title == "Finalization timed out")
        #expect(bridge.trayState.lastOutcome?.kind == .recoveryNeeded)

        let recovered = try await queue.recover(id: pending[0].id)
        let artifacts = try await queue.fetchAll()
        bridge.setRecoveryArtifacts(artifacts)

        #expect(recovered.status == .recovered)
        #expect(recovered.recordingID != nil)
        #expect(RecoveryInboxModel.unresolvedCount(in: bridge.recoveryArtifacts) == 0)
        #expect(try await fixture.store.fetch(id: recovered.recordingID!)?.title == "Recovered interrupted recording")
        #expect(FileManager.default.fileExists(atPath: cacheWAV.path) == false)
    }
}

private struct CustomerExperienceFixture {
    let rootURL: URL
    let recordingsURL: URL
    let notesURL: URL
    let cacheURL: URL
    let store: RecordingStore
    let noteStore: NoteStore

    static func make() async throws -> CustomerExperienceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-customer-e2e-\(UUID().uuidString)", isDirectory: true)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        return CustomerExperienceFixture(
            rootURL: root,
            recordingsURL: recordings,
            notesURL: notes,
            cacheURL: cache,
            store: try await RecordingStore.inMemory(),
            noteStore: NoteStore(rootURL: notes)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func seedRecording(
        stem: String,
        title: String,
        transcript: String,
        pinned: Bool,
        startedAt: Date = date(year: 2026, month: 5, day: 18, hour: 10),
        speakerNames: [Int: String] = [0: "Speaker 1", 1: "Speaker 2"],
        tags: [String] = []
    ) async throws -> Recording {
        let paths = try writeCompletedRecording(
            stem: stem,
            title: title,
            transcript: transcript,
            startedAt: startedAt,
            speakerNames: speakerNames,
            tags: tags
        )
        return try await store.upsert(Recording(
            wavPath: paths.wavURL.path,
            txtPath: paths.txtURL.path,
            jsonPath: paths.jsonURL.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            title: title,
            transcriptText: transcript,
            tags: tags,
            speakerNames: speakerNames,
            pinned: pinned
        ))
    }

    func writeCompletedRecording(
        stem: String,
        title: String,
        transcript: String,
        startedAt: Date = date(year: 2026, month: 5, day: 18, hour: 9),
        speakerNames: [Int: String] = [:],
        tags: [String] = [],
        summary: String = "",
        actionItems: String = ""
    ) throws -> CompletedRecordingFixture {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: startedAt)
        let month = calendar.component(.month, from: startedAt)
        let day = calendar.component(.day, from: startedAt)
        let dayURL = recordingsURL
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%04d-%02d-%02d", year, month, day), isDirectory: true)
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let wavURL = dayURL.appendingPathComponent("\(stem).wav")
        let txtURL = dayURL.appendingPathComponent("\(stem).txt")
        let jsonURL = dayURL.appendingPathComponent("\(stem).json")
        try Data(repeating: 7, count: 256).write(to: wavURL)
        try transcript.write(to: txtURL, atomically: true, encoding: .utf8)
        try transcriptJSON(
            audioPath: wavURL.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            text: transcript
        ).write(to: jsonURL, atomically: true, encoding: .utf8)

        return CompletedRecordingFixture(
            title: title,
            wavURL: wavURL,
            txtURL: txtURL,
            jsonURL: jsonURL,
            speakerNames: speakerNames,
            tags: tags,
            summary: summary,
            actionItems: actionItems
        )
    }

    static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    static func writeRecoverableWAV(to url: URL) throws {
        var out = Data()
        let pcm = Data(repeating: 1, count: 320)
        out.append(Data("RIFF".utf8))
        out.append(littleEndianUInt32Bytes(UInt32(36 + pcm.count)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(littleEndianUInt32Bytes(16))
        out.append(littleEndianUInt16Bytes(1))
        out.append(littleEndianUInt16Bytes(1))
        out.append(littleEndianUInt32Bytes(16_000))
        out.append(littleEndianUInt32Bytes(32_000))
        out.append(littleEndianUInt16Bytes(2))
        out.append(littleEndianUInt16Bytes(16))
        out.append(Data("data".utf8))
        out.append(littleEndianUInt32Bytes(UInt32(pcm.count)))
        out.append(pcm)
        try out.write(to: url, options: .atomic)
    }

    private func transcriptJSON(audioPath: String, startedAt: Date, endedAt: Date, text: String) -> String {
        let words = text
            .split(separator: " ")
            .enumerated()
            .map { index, token in
                #"{"endMs":\#((index + 1) * 500),"startMs":\#(index * 500),"text":"\#(String(token).replacingOccurrences(of: #"""#, with: #"\""#))"}"#
            }
            .joined(separator: ",")
        let midpoint = max(500, (text.split(separator: " ").count / 2) * 500)
        return """
        {
          "audioPath": "\(audioPath)",
          "chunks": [],
          "endedAt": \(Int(endedAt.timeIntervalSince1970)),
          "joinedText": "\(text.replacingOccurrences(of: #"""#, with: #"\""#))",
          "speakers": [
            {"endMs": \(midpoint), "speaker": 0, "startMs": 0},
            {"endMs": 90000, "speaker": 1, "startMs": \(midpoint)}
          ],
          "startedAt": \(Int(startedAt.timeIntervalSince1970)),
          "words": [\(words)]
        }
        """
    }

    private static func littleEndianUInt16Bytes(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }

    private static func littleEndianUInt32Bytes(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}

private struct CompletedRecordingFixture {
    let title: String
    let wavURL: URL
    let txtURL: URL
    let jsonURL: URL
    let speakerNames: [Int: String]
    let tags: [String]
    let summary: String
    let actionItems: String
}

private func waitForCustomerExperienceState(
    timeout: TimeInterval = 1,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
