import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcClient
import HarcCore
import HarcStore
@testable import HarcUI

@MainActor
@Suite("TranscriptEditorViewModel")
struct TranscriptEditorViewModelTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-vm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSilenceWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = 0 }
        try file.write(from: buf)
    }

    private struct Fixture {
        let dir: URL
        let wav: URL
        let txt: URL
        let json: URL
        let store: RecordingStore
        let recording: Recording
    }

    private func makeFixture(withAudio: Bool = true) async throws -> Fixture {
        let dir = try makeTempDir()
        let wav = dir.appendingPathComponent("10-00-00.wav")
        let txt = dir.appendingPathComponent("10-00-00.txt")
        let json = dir.appendingPathComponent("10-00-00.json")

        if withAudio {
            try writeSilenceWAV(to: wav, seconds: 1.0)
        }
        try "original text".write(to: txt, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(SessionTranscript(
            startedAt: Date(), endedAt: Date(), audioPath: wav.path,
            joinedText: "original text",
            words: [Word(text: "original", startMs: 0, endMs: 500),
                    Word(text: "text", startMs: 500, endMs: 1000)],
            speakers: [], chunks: []
        )).write(to: json)

        let store = try await RecordingStore.inMemory()
        let saved = try await store.upsert(Recording(
            wavPath: wav.path,
            txtPath: txt.path,
            jsonPath: json.path,
            startedAt: Date(),
            transcriptText: "original text"
        ))
        return Fixture(dir: dir, wav: wav, txt: txt, json: json, store: store, recording: saved)
    }

    @Test("load: editedText matches document.initialText, isDirty false")
    func loadHappyPath() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        #expect(vm.editedText == "original text")
        #expect(!vm.isDirty)
        #expect(!vm.audioMissing)
        #expect(vm.durationSec > 0.9 && vm.durationSec < 1.1)
    }

    @Test("markEdited sets dirty + stale flags")
    func markEdited() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        vm.markEdited(newText: "edited")
        #expect(vm.isDirty)
        #expect(vm.wordIndexStale)
        #expect(vm.editedText == "edited")
    }

    @Test("save writes .txt, updates store, clears dirty")
    func saveFlow() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        vm.markEdited(newText: "edited")
        await vm.save()
        #expect(!vm.isDirty)
        #expect(vm.saveError == nil)

        let onDisk = try String(contentsOf: f.txt, encoding: .utf8)
        #expect(onDisk == "edited")

        let reFetch = try await f.store.fetchByWavPath(f.recording.wavPath)
        #expect(reFetch?.transcriptText == "edited")
    }

    @Test("missing audio: audioMissing true, togglePlay is a no-op")
    func missingAudio() async throws {
        let f = try await makeFixture(withAudio: false)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        #expect(vm.audioMissing)
        vm.togglePlay()
        #expect(!vm.isPlaying)
    }

    @Test("save still works when audio is missing")
    func saveWithoutAudio() async throws {
        let f = try await makeFixture(withAudio: false)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        vm.markEdited(newText: "yes")
        await vm.save()
        #expect(!vm.isDirty)
        #expect(try String(contentsOf: f.txt, encoding: .utf8) == "yes")
    }

    @Test("save error persists until dismissed")
    func clearSaveError() async throws {
        let f = try await makeFixture()
        let vm = await TranscriptEditorViewModel(recording: f.recording, store: f.store)
        try FileManager.default.removeItem(at: f.dir)

        vm.markEdited(newText: "cannot write")
        await vm.save()
        #expect(vm.saveError != nil)

        vm.clearSaveError()
        #expect(vm.saveError == nil)
    }
}
