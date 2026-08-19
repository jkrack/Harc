import Foundation
import HarcClient
import HarcClientStore
import HarcCore
import HarcDomain
import HarcStore
import Testing
@testable import Harc

@Suite("Desktop Client local-library Reprocess")
struct HarcDesktopLocalLibraryReprocessorTests {
    @Test("one local row has one stable per-device origin")
    func stableOrigin() throws {
        let source = CanonicalRecordingID(
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )
        let deviceA = try DeviceID(Data(repeating: 0x11, count: 32))
        let deviceB = try DeviceID(Data(repeating: 0x22, count: 32))

        let first = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: source,
            deviceID: deviceA
        )
        let retry = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: source,
            deviceID: deviceA
        )
        let anotherDevice = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: source,
            deviceID: deviceB
        )

        #expect(first == retry)
        #expect(first != anotherDevice)
        #expect(first.deviceID == deviceA)
    }

    @Test("missing structured data and stale provenance require local processing")
    func processingDecision() {
        let current = "parakeet-current"
        var recording = Recording(
            wavPath: "/tmp/source.wav",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let transcript = SessionTranscript(
            startedAt: recording.startedAt,
            endedAt: recording.startedAt.addingTimeInterval(1),
            audioPath: recording.wavPath,
            joinedText: "hello",
            words: [],
            speakers: [],
            chunks: []
        )

        #expect(HarcDesktopLocalLibraryReprocessPlanner.shouldTranscribe(
            recording: recording,
            structuredTranscript: transcript,
            currentModelID: current
        ))
        recording.sttModelID = current
        #expect(!HarcDesktopLocalLibraryReprocessPlanner.shouldTranscribe(
            recording: recording,
            structuredTranscript: transcript,
            currentModelID: current
        ))
        #expect(HarcDesktopLocalLibraryReprocessPlanner.shouldTranscribe(
            recording: recording,
            structuredTranscript: nil,
            currentModelID: current
        ))
    }

    @Test("structured transcript loader honors Harc's seconds-since-1970 format")
    func loadsStructuredTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-reprocess-transcript-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jsonURL = root.appendingPathComponent("recording.json")
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000.25)
        let transcript = SessionTranscript(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3),
            audioPath: "/tmp/source.wav",
            joinedText: "locally processed",
            words: [],
            speakers: [],
            chunks: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(transcript).write(to: jsonURL)
        let recording = Recording(
            wavPath: "/tmp/source.wav",
            jsonPath: jsonURL.path,
            startedAt: startedAt
        )

        let loaded = HarcDesktopLocalLibraryReprocessPlanner
            .loadStructuredTranscript(for: recording)
        #expect(loaded == transcript)
    }

    @Test("staging is durable, repeat-safe, and preserves the On This Mac master")
    func durableIdempotentStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "harc-reprocess-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("on-this-mac.wav")
        let sourceBytes = makeWAV(pcm: Data([1, 2, 3, 4, 5, 6]))
        try sourceBytes.write(to: source)
        let deviceID = try DeviceID(Data(repeating: 0x44, count: 32))
        let transferStore = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: deviceID
        )
        let startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let recording = Recording(
            wavPath: source.path,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3),
            canonicalID: CanonicalRecordingID(
                UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
            )
        )
        let transcript = SessionTranscript(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3),
            audioPath: source.path,
            joinedText: "safe local copy",
            words: [],
            speakers: [],
            chunks: []
        )

        let first = try await HarcDesktopLocalLibraryStager.enqueue(
            recording,
            transcript: transcript,
            speakerEmbeddings: [],
            deviceID: deviceID,
            transferStore: transferStore,
            root: root
        )
        let retry = try await HarcDesktopLocalLibraryStager.enqueue(
            recording,
            transcript: transcript,
            speakerEmbeddings: [],
            deviceID: deviceID,
            transferStore: transferStore,
            root: root
        )

        #expect(first == .queued)
        #expect(retry == .alreadyQueued)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try transferStore.recordingOutboxes().count == 1)
        let origin = HarcDesktopLocalLibraryReprocessPlanner.originRecordingID(
            sourceCanonicalID: recording.canonicalID,
            deviceID: deviceID
        )
        let sidecarURL = root.appendingPathComponent("Captures", isDirectory: true)
            .appendingPathComponent(
                "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
            )
        let sidecar = try JSONDecoder().decode(
            HarcDesktopClientCaptureSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        #expect(sidecar.sourceLocalCanonicalID == recording.canonicalID)
        #expect(sidecar.transcript?.audioPath != source.path)
    }

    private func makeWAV(pcm: Data) -> Data {
        var wav = Data("RIFF".utf8)
        appendLittleEndian(UInt32(pcm.count + 36), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt32(16_000), to: &wav)
        appendLittleEndian(UInt32(32_000), to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
