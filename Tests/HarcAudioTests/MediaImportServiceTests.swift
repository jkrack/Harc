import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import HarcAudio
import HarcClient
import HarcCore

// MARK: - Mocks

/// Echo client — returns a fixed text per chunk and records call shapes.
private final class MockTranscribingClient: TranscribingClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(path: String, diarize: Bool, vad: Bool)] = []
    var textPerChunk: String
    var shouldFail: Bool

    init(textPerChunk: String = "hello world", shouldFail: Bool = false) {
        self.textPerChunk = textPerChunk
        self.shouldFail = shouldFail
    }

    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        let fail = record(path: audioPath, diarize: diarize, vad: vad)
        if fail { throw ClientError.daemonNotReachable("mock failure") }
        return TranscribeResult(text: textPerChunk, words: [], speakers: [], processingMs: 1)
    }

    private func record(path: String, diarize: Bool, vad: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls.append((path, diarize, vad))
        return shouldFail
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }
}

// MARK: - Fixtures

/// Write a WAV of `seconds` of a 440 Hz sine at 16 kHz mono — the app's
/// native shape, importable directly.
private func makeWAVFixture(seconds: Double, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("fixture-\(UUID().uuidString.prefix(6)).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.floatChannelData![0]
    for i in 0..<Int(frames) {
        channel[i] = sinf(2 * .pi * 440 * Float(i) / 16_000) * 0.5
    }
    try file.write(from: buffer)
    return url
}

/// Write an m4a (AAC, 44.1 kHz stereo) sine fixture — exercises the real
/// decode + downmix + resample path.
private func makeM4AFixture(seconds: Double, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("fixture-\(UUID().uuidString.prefix(6)).m4a")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false
    )!
    let frames = AVAudioFrameCount(seconds * 44_100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<2 {
        let channel = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / 44_100) * 0.5
        }
    }
    try file.write(from: buffer)
    return url
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("harc-import-tests-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Suite("MediaImportService")
struct MediaImportServiceTests {
    @Test("unsupported extension is rejected before any file I/O")
    func unsupportedType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("notes.txt")
        try "not audio".write(to: bogus, atomically: true, encoding: .utf8)

        let service = MediaImportService(
            client: MockTranscribingClient(),
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: dir)
        )
        await #expect(throws: MediaImportError.unsupportedType("txt")) {
            _ = try await service.importFile(source: bogus)
        }
    }

    @Test("garbage bytes with a media extension throw a conversion error, not a crash")
    func corruptMediaFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("broken.mov")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: junk)

        let service = MediaImportService(
            client: MockTranscribingClient(),
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: dir)
        )
        await #expect(throws: (any Error).self) {
            _ = try await service.importFile(source: junk)
        }
    }

    @Test("wav import lands in YYYY/YYYY-MM-DD/HH-mm-ss.wav with txt+json siblings and original title")
    func wavImportEndToEnd() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeWAVFixture(seconds: 2.0, in: dir)
        let base = dir.appendingPathComponent("library")
        let client = MockTranscribingClient(textPerChunk: "imported words")

        let service = MediaImportService(
            client: client,
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: base)
        )
        let importedAt = Date()
        let result = try await service.importFile(source: source, importedAt: importedAt)

        // Destination shape: <base>/YYYY/YYYY-MM-DD/HH-mm-ss.wav
        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: importedAt))
        #expect(result.recording.wavURL.path.hasPrefix(base.appendingPathComponent(year).path))
        #expect(result.recording.wavURL.pathExtension == "wav")
        let dayDir = result.recording.wavURL.deletingLastPathComponent().lastPathComponent
        #expect(dayDir.hasPrefix(year))  // YYYY-MM-DD

        // Siblings exist and carry the transcript.
        let txtURL = try #require(result.recording.txtURL)
        let jsonURL = try #require(result.recording.jsonURL)
        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let txt = try String(contentsOf: txtURL, encoding: .utf8)
        #expect(txt.contains("imported words"))

        // Original filename (sans extension) is the title; duration ≈ 2 s.
        #expect(result.originalTitle == source.deletingPathExtension().lastPathComponent)
        #expect(abs(result.durationSeconds - 2.0) < 0.1)

        // One short file → one chunk, diarize off per-chunk.
        #expect(client.callCount == 1)
        #expect(client.calls.allSatisfy { !$0.diarize })
    }

    @Test("m4a import converts to a readable 16 kHz mono WAV")
    func m4aConversion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeM4AFixture(seconds: 2.0, in: dir)
        let base = dir.appendingPathComponent("library")

        let service = MediaImportService(
            client: MockTranscribingClient(),
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: base)
        )
        let result = try await service.importFile(source: source)

        let wav = try AVAudioFile(forReading: result.recording.wavURL)
        #expect(wav.fileFormat.sampleRate == 16_000)
        #expect(wav.fileFormat.channelCount == 1)
        let duration = Double(wav.length) / wav.fileFormat.sampleRate
        #expect(abs(duration - 2.0) < 0.25)  // AAC priming/padding tolerance
    }

    @Test("progress runs converting → transcribing → finalizing and ends at 1.0")
    func progressPhases() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeWAVFixture(seconds: 2.0, in: dir)
        let base = dir.appendingPathComponent("library")

        let service = MediaImportService(
            client: MockTranscribingClient(),
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: base)
        )

        final class Ticks: @unchecked Sendable {
            let lock = NSLock()
            var items: [MediaImportProgress] = []
            func add(_ p: MediaImportProgress) {
                lock.lock(); items.append(p); lock.unlock()
            }
        }
        let ticks = Ticks()
        _ = try await service.importFile(source: source) { ticks.add($0) }

        let phases = ticks.items.map(\.phase)
        #expect(phases.contains(.converting))
        #expect(phases.contains(.transcribing))
        #expect(phases.contains(.finalizing))
        #expect(ticks.items.last?.fraction == 1.0)
        // Monotone non-decreasing overall fraction.
        #expect(zip(ticks.items, ticks.items.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    @Test("all chunks failing throws transcriptionFailed and leaves no cache orphan behind in the library")
    func allChunksFail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeWAVFixture(seconds: 2.0, in: dir)
        let base = dir.appendingPathComponent("library")

        let service = MediaImportService(
            client: MockTranscribingClient(shouldFail: true),
            diarizer: nil,
            destination: RecordingDestination(baseDirectory: base)
        )
        await #expect(throws: (any Error).self) {
            _ = try await service.importFile(source: source)
        }
        // Nothing must land in the destination on failure.
        #expect(!FileManager.default.fileExists(atPath: base.path)
                || (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.isEmpty == true)
    }

    @Test("supported-extension matrix")
    func supportedMatrix() {
        #expect(MediaImportService.isSupported(URL(fileURLWithPath: "/a/b.mp3")))
        #expect(MediaImportService.isSupported(URL(fileURLWithPath: "/a/b.MOV")))
        #expect(MediaImportService.isSupported(URL(fileURLWithPath: "/a/b.m4a")))
        #expect(!MediaImportService.isSupported(URL(fileURLWithPath: "/a/b.txt")))
        #expect(!MediaImportService.isSupported(URL(fileURLWithPath: "/a/b")))
    }

    @Test("cancelling mid-transcription throws CancellationError and leaves no artifacts")
    func cancellationCleansUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Long enough for several 1s chunks so a cancellation point is
        // guaranteed to run between chunks.
        let source = try makeWAVFixture(seconds: 5.0, in: dir)
        let base = dir.appendingPathComponent("library")

        // Client that signals when the first chunk arrives, then stalls
        // (cancellation-cooperatively) so the import is provably in flight
        // when the test cancels it.
        final class StallingClient: TranscribingClient, @unchecked Sendable {
            let firstCall = AsyncStream<Void>.makeStream()
            func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
                firstCall.continuation.yield()
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                throw CancellationError()
            }
        }
        let client = StallingClient()
        let importer = Task {
            try await MediaImportService(
                client: client,
                diarizer: nil,
                destination: RecordingDestination(baseDirectory: base)
            ).importFile(
                source: source,
                options: MediaImportService.Options(chunkDurationSeconds: 1.0)
            )
        }

        // Wait until the first chunk is being transcribed, then cancel.
        var iterator = client.firstCall.stream.makeAsyncIterator()
        _ = await iterator.next()
        importer.cancel()

        let result = await importer.result
        switch result {
        case .success:
            Issue.record("import completed despite cancellation")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        // Nothing lands in the destination on cancel.
        #expect(!FileManager.default.fileExists(atPath: base.path)
                || (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.isEmpty == true)
    }
}
