import AVFAudio
import XCTest
@testable import HarcMobile

final class HarcMobileAudioEnvelopeTests: XCTestCase {
    @MainActor
    func testLocalPlaybackRestoresOutputSessionWhenResumingAfterCapture() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-playback-route-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<160_000 { samples[index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let session = AVAudioSession.sharedInstance()
        let controller = HarcMobileLocalRecordingAudioController(url: url)
        defer { controller.stop() }
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        await controller.playOrPause()
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(session.category, .playback)
        XCTAssertFalse(session.currentRoute.outputs.isEmpty)
        XCTAssertFalse(session.currentRoute.outputs.contains { $0.portType == .builtInReceiver })
        print("Tide initial playback route: \(session.currentRoute.outputs.map { $0.portType.rawValue })")

        await controller.playOrPause()
        XCTAssertEqual(controller.state, .paused)
        // Capture can change the app-wide session while this player is paused.
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        await controller.playOrPause()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertFalse(session.currentRoute.outputs.isEmpty)
        XCTAssertFalse(session.currentRoute.outputs.contains { $0.portType == .builtInReceiver })
        print("Tide resumed playback route: \(session.currentRoute.outputs.map { $0.portType.rawValue })")
    }

    @MainActor
    func testLongLocalPlaybackSeeksExactlyWhilePaused() async throws {
        let sampleRate = 16_000.0
        let oneFrame = 1.0 / sampleRate
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-long-paused-seek-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
            channels: 1, interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for frame in 0..<16_000 { samples[frame] = 0 }
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
            // Reuse one second of silence instead of allocating ten minutes.
            for _ in 0..<600 { try file.write(from: buffer) }
        }
        let source = try AVAudioFile(forReading: url)
        XCTAssertEqual(source.length, 9_600_000)
        XCTAssertEqual(source.processingFormat.sampleRate, sampleRate)

        var createdPlayer: AVAudioPlayer?
        let controller = HarcMobileLocalRecordingAudioController(url: url, makePlayer: { url in
            let player = try AVAudioPlayer(contentsOf: url)
            createdPlayer = player
            return player
        })
        defer { controller.stop() }
        await controller.playOrPause()
        let player = try XCTUnwrap(createdPlayer)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertTrue(player.isPlaying)
        await controller.playOrPause()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(controller.duration, 600, accuracy: oneFrame)
        XCTAssertEqual(player.duration, 600, accuracy: oneFrame)

        controller.seek(to: 300)
        XCTAssertEqual(controller.currentTime, 300, accuracy: oneFrame)
        XCTAssertEqual(player.currentTime, 300, accuracy: oneFrame)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(player.isPlaying)
        let pausedTime = player.currentTime
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: oneFrame)
        XCTAssertEqual(controller.currentTime, 300, accuracy: oneFrame)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testLocalPreparationDerivesWaveformWithoutClaimingPlaybackSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-local-envelope-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<16_000 { samples[frame] = frame < 8_000 ? 0 : 0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var activations = 0
        let session = HarcMobilePlaybackSession(activate: { activations += 1 }, deactivate: {})
        let controller = HarcMobileLocalRecordingAudioController(url: url, session: session)
        session.beginCapture()
        await controller.prepare()
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.duration, 1, accuracy: 0.001)
        XCTAssertTrue(controller.canSeek)
        XCTAssertEqual(controller.envelope.count, 320)
        XCTAssertTrue(controller.envelope.prefix(160).allSatisfy { $0 == 0 })
        XCTAssertTrue(controller.envelope.suffix(160).allSatisfy { abs($0 - 0.5) < 0.001 })
        controller.seek(to: 0.5)
        XCTAssertEqual(controller.currentTime, 0.5)
        controller.stop()
        XCTAssertEqual(activations, 0)
        session.endCapture()
    }

    @MainActor
    func testCancelledLocalPreparationDoesNotPublishDisplayData() async throws {
        let controller = HarcMobileLocalRecordingAudioController(
            url: URL(fileURLWithPath: "/missing-local-recording.wav")
        )
        let task = Task { await controller.prepare() }
        task.cancel()
        await task.value
        XCTAssertEqual(controller.duration, 0)
        XCTAssertTrue(controller.envelope.isEmpty)
        XCTAssertFalse(controller.canSeek)
        XCTAssertEqual(controller.state, .idle)
    }

    func testEnvelopePreservesSilenceAndLocalizedAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-envelope-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<16_000 { channel[frame] = frame < 8_000 ? 0 : 0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let envelope = try HarcMobileRecordingAudioController.readEnvelope(url: url)
        XCTAssertEqual(envelope.count, 320)
        XCTAssertTrue(envelope.prefix(160).allSatisfy { $0 == 0 })
        XCTAssertTrue(envelope.suffix(160).allSatisfy { abs($0 - 0.5) < 0.001 })
    }
}
