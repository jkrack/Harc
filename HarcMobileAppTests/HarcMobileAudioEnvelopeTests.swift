import AVFAudio
import XCTest
@testable import HarcMobile

final class HarcMobileAudioEnvelopeTests: XCTestCase {
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
