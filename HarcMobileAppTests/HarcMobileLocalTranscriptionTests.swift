import Foundation
import HarcAudioMobile
import HarcDomain
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobileLocalTranscriptionTests: XCTestCase {
    func testPreviewPersistsSeparatelyAndExactRetryReusesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.request.audioURL)
        try await fixture.store.register(fixture.request)
        try await fixture.store.register(fixture.request)
        try await fixture.store.save(fixture.result, for: fixture.request)
        try await fixture.store.save(fixture.result, for: fixture.request)
        let loaded = try await fixture.store.load(fixture.request)
        XCTAssertEqual(loaded, fixture.result)
        XCTAssertEqual(try Data(contentsOf: fixture.request.audioURL), before)
        // A derived preview remains usable after an independent safe master cleanup.
        try FileManager.default.removeItem(at: fixture.request.audioURL)
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store) { _ in
            XCTFail("A retained preview must not repeat inference")
            throw HarcMobileTranscriptionError.unavailable
        }
        await coordinator.restore([fixture.request])
        XCTAssertEqual(coordinator.states[fixture.request.id], .available)
        await coordinator.loadPreview(fixture.request.id)
        XCTAssertEqual(coordinator.states[fixture.request.id], .ready(fixture.result))
    }

    func testRejectsWrongAudioBindingAndInvalidTimeline() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrong = HarcMobileLocalTranscript(origin: fixture.result.origin,
            pcmHash: try CanonicalPCMHash(Data(repeating: 7, count: 32)),
            frames: fixture.result.frames, localeIdentifier: "en-US",
            engine: "apple-speechtranscriber-v1", segments: [])
        XCTAssertThrowsError(try wrong.validate(for: fixture.request))
        let invalid = HarcMobileLocalTranscript(origin: fixture.result.origin,
            pcmHash: fixture.result.pcmHash, frames: fixture.result.frames,
            localeIdentifier: "en-US", engine: "apple-speechtranscriber-v1",
            segments: [.init(start: 3, end: 2, text: "bad")])
        XCTAssertThrowsError(try invalid.validate(for: fixture.request))
    }

    func testCaptureSuspendsQueueAndModelFailureLeavesAudioUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.request.audioURL)
        let calls = Calls()
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store) { _ in
            await calls.add()
            throw HarcMobileTranscriptionError.needsModel
        }
        coordinator.setCaptureActive(true)
        coordinator.enqueue(fixture.request)
        XCTAssertEqual(coordinator.states[fixture.request.id], .queued)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        coordinator.setCaptureActive(false)
        await settle { coordinator.states[fixture.request.id] == .needsModel }
        XCTAssertEqual(coordinator.states[fixture.request.id], .needsModel)
        XCTAssertEqual(try Data(contentsOf: fixture.request.audioURL), before)
    }

    func testInterruptedWorkCannotPublishPartialResultAndResumesOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store) { _ in
            await gate.wait()
            return fixture.result
        }
        coordinator.enqueue(fixture.request)
        coordinator.enqueue(fixture.request)
        await settle { coordinator.states[fixture.request.id] == .transcribing }
        coordinator.setForeground(false)
        await gate.open()
        await settle { coordinator.states[fixture.request.id] == .queued }
        let interrupted = try await fixture.store.load(fixture.request)
        XCTAssertNil(interrupted)
        coordinator.setForeground(true)
        await settle { coordinator.states[fixture.request.id] == .ready(fixture.result) }
        XCTAssertEqual(coordinator.states[fixture.request.id], .ready(fixture.result))
    }

    func testMismatchedRequestCannotRelabelAnActiveJob() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store) { _ in
            await gate.wait()
            return fixture.result
        }
        coordinator.enqueue(fixture.request)
        await settle { coordinator.states[fixture.request.id] == .transcribing }
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fixture.request)) as? [String: Any])
        changed["audioURL"] = "file:///not-the-original.wav"
        let foreign = try JSONDecoder().decode(HarcMobileTranscriptRequest.self,
            from: JSONSerialization.data(withJSONObject: changed))
        coordinator.enqueue(foreign)
        XCTAssertEqual(coordinator.states[fixture.request.id], .transcribing)
        await gate.open()
        await settle { coordinator.states[fixture.request.id] == .ready(fixture.result) }
        XCTAssertEqual(coordinator.states[fixture.request.id], .ready(fixture.result))
    }

    func testBackgroundLaunchDefersInferenceUntilForeground() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store, foreground: false) { _ in
            fixture.result
        }
        coordinator.enqueue(fixture.request)
        XCTAssertEqual(coordinator.states[fixture.request.id], .queued)
        coordinator.setCaptureActive(false)
        XCTAssertEqual(coordinator.states[fixture.request.id], .queued)
        for _ in 0..<200 {
            if await fixture.store.isRegistered(fixture.request) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let registered = await fixture.store.isRegistered(fixture.request)
        XCTAssertTrue(registered, "Background stop must persist pending work without starting STT")
        coordinator.setForeground(true)
        await settle { coordinator.states[fixture.request.id] == .ready(fixture.result) }
    }

    func testRestoreDoesNotStartUnrequestedHistoricalWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = HarcMobileLocalTranscriptionCoordinator(store: fixture.store) { _ in
            XCTFail("Old captures without a local job should not start processing")
            throw HarcMobileTranscriptionError.unavailable
        }
        await coordinator.restore([fixture.request])
        XCTAssertNil(coordinator.states[fixture.request.id])
    }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Coordinator failed to reach expected state")
    }

    private actor Calls {
        var count = 0
        func add() { count += 1 }
    }
    private actor Gate {
        var isOpen = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { isOpen = true; continuation?.resume(); continuation = nil }
    }

    private struct Fixture: Sendable {
        let root: URL
        let store: HarcMobileLocalTranscriptStore
        let request: HarcMobileTranscriptRequest
        let result: HarcMobileLocalTranscript
        @MainActor init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let locations = try HarcMobileCaptureLocations(applicationSupportRoot: root)
            let writer = try HarcMobileDurableMasterWriter(locations: locations,
                producingDeviceID: DeviceID(Data(repeating: 0x63, count: 32)), captureStartedAt: Date(timeIntervalSince1970: 1_900_000_000),
                captureStartedMonotonicNanoseconds: 1_000, attributes: Attributes())
            try writer.appendCanonicalPCM(Data(repeating: 1, count: 32_000),
                endedAt: Date(timeIntervalSince1970: 1_900_000_001),
                endedMonotonicNanoseconds: 1_000_001_000)
            let master = try writer.finalize(reason: .userStopped)
            request = HarcMobileTranscriptRequest(capture: try HarcMobileAppModel.finalizedCapture(master),
                audioURL: master.masterFileURL)
            result = HarcMobileLocalTranscript(origin: request.origin, pcmHash: request.pcmHash,
                frames: request.frames, localeIdentifier: "en-US", engine: "apple-speechtranscriber-v1",
                segments: [.init(start: 0, end: 1, text: "A synthetic transcript.")])
            store = HarcMobileLocalTranscriptStore(root: root.appendingPathComponent("Derived"), attributes: Attributes())
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private struct Attributes: HarcMobileCaptureStorageAttributeApplying {
        func applyAndVerify(_ policy: HarcMobileCaptureStoragePolicy, to url: URL) throws {}
    }
}
