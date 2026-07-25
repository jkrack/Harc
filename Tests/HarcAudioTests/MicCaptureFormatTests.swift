import Testing
@preconcurrency import AVFoundation
@testable import HarcAudio

@Suite("MicCapture input format")
struct MicCaptureFormatTests {
    /// An input node with no usable device reports 0 ch / 0 Hz. That is what a
    /// process without effective microphone access sees, and it is the state
    /// that made retroactive record fail with a bare
    /// "com.apple.coreaudio.avfaudio error -10868".
    @Test("a zero-channel, zero-rate format is not a usable input")
    func zeroFormatIsInvalid() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let unusable = AVAudioFormat(streamDescription: &asbd)

        // A 0 ch / 0 Hz description may not even construct a format; either
        // way it must never be treated as a usable input.
        if let unusable {
            #expect(MicCapture.isValidInputFormat(unusable) == false)
        }
    }

    @Test("a real hardware format is a usable input")
    func realFormatIsValid() throws {
        let good = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
        )

        #expect(MicCapture.isValidInputFormat(good) == true)
    }

    /// The start-up guard accepts *either* format, which is exactly how an
    /// unusable input paired with a healthy output slipped through to
    /// `engine.start()` and failed there instead of being reported up front.
    @Test("identical formats are not offered twice as tap candidates")
    func candidatesDoNotDuplicate() throws {
        let good = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
        )

        let candidates = MicCapture.tapFormatCandidates(outputFormat: good, inputFormat: good)

        // nil (device-native) first, then the valid format once.
        #expect(candidates.count == 2)
        #expect(candidates[0] == nil)
    }
}
