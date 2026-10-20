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
