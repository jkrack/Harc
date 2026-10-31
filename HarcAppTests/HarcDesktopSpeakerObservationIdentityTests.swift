import Foundation
import CryptoKit
import HarcClient
import Testing
import HarcDomain
import HarcCore
@testable import Harc

@Suite("Desktop speaker observation model identity")
struct HarcDesktopSpeakerObservationIdentityTests {
    private func origin() throws -> OriginRecordingID {
        OriginRecordingID(deviceID: try DeviceID(Data(repeating: 1, count: 32)),
                          recordingUUID: try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))
    }
    @Test func invalidSpeakerRowsCannotProducePartialSubmission() throws {
        let source = try origin(), canonical = CanonicalRecordingID.random()
        let digest = Data(repeating: 1, count: 32)
        let valid = SpeakerEmbeddingRow(speakerIndex: 0, vector: [1, 0], totalMs: 6000, segmentCount: 1)
        func prepare(_ rows: [SpeakerEmbeddingRow]) throws -> [SpeakerEmbeddingObservation] {
            try HarcDesktopClientTransferCoordinator.prepareSpeakerObservations(rows, origin: source,
                canonicalID: canonical, pack: nil, sidecarSHA256: digest)
        }
        let invalidRows: [SpeakerEmbeddingRow] = [
            .init(speakerIndex: -1, vector: [1, 0], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: Int.max, vector: [1, 0], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [1, 0], totalMs: 0, segmentCount: 1),
            .init(speakerIndex: 1, vector: [1, 0], totalMs: -1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [1, 0], totalMs: 1, segmentCount: 0),
            .init(speakerIndex: 1, vector: [1, 0], totalMs: 1, segmentCount: Int.max),
            .init(speakerIndex: 1, vector: [0, 0], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [.nan, 1], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [.infinity, 1], totalMs: 1, segmentCount: 1),
            .init(speakerIndex: 1, vector: [1, 0], totalMs: 1, segmentCount: 1, modelID: "")
        ]
        for invalid in invalidRows {
            #expect(throws: (any Error).self) { try prepare([valid, invalid]) }
        }
        #expect(throws: (any Error).self) { try prepare([valid, valid]) }
        let second = SpeakerEmbeddingRow(speakerIndex: 1, vector: [0, 1], totalMs: 4000, segmentCount: 2)
        let prepared = try prepare([valid, second])
        #expect(prepared.map(\.speakerIndex) == [0, 1])
        #expect(prepared.map(\.speechDurationMs) == [6000, 4000])
        #expect(Set(prepared.map(\.operationID)).count == 2)
        #expect(try prepare([valid, second]) == prepared)
    }

    @Test func evidenceBoundRetryRejectsStaleCompletionAndSeparatesChangedRequests() throws {
        let canonical = CanonicalRecordingID.random()
        let baseID = HarcDesktopClientTransferCoordinator.observationOperationID(
            origin: try origin(), speakerIndex: 0, modelID: "wespeaker_v2", packRevision: try EntityRevision(7))
        func observation(canonicalID: CanonicalRecordingID? = nil, vector: [Float] = [1, 0],
                         duration: UInt64 = 6000, person: PersonID? = nil) throws -> SpeakerEmbeddingObservation {
            try SpeakerEmbeddingObservation(operationID: baseID,
                canonicalRecordingID: canonicalID ?? canonical, speakerIndex: 0,
                embedding: QuantizedSpeakerEmbedding.quantizing(vector), modelID: "wespeaker_v2",
                speechDurationMs: duration, segmentCount: 1, sourcePackRevision: EntityRevision(7),
                proposedPersonID: person, proposedScore: person == nil ? nil : 0.8)
        }
        let sidecar = Data("original captured sidecar".utf8)
        let digest = Data(SHA256.hash(data: sidecar))
        let first = try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(observation(), sidecarSHA256: digest)
        let retry = try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(observation(), sidecarSHA256: digest)
        #expect(first == retry)
        #expect(first.operationID != baseID)
        for changed in [try observation(canonicalID: .random()), try observation(vector: [0, 1]),
                        try observation(duration: 7000), try observation(person: .random())] {
            let bound = try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(changed, sidecarSHA256: digest)
            #expect(bound.operationID != first.operationID)
        }
        let replacement = Data("replacement captured sidecar".utf8)
        let changed = try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(observation(),
            sidecarSHA256: Data(SHA256.hash(data: replacement)))
        #expect(changed.operationID != first.operationID)
        let marker = HarcDesktopSpeakerObservationMarker(canonicalRecordingID: canonical,
            sourcePackRevision: try EntityRevision(7), decisions: [], acceptedAt: Date(), sidecarSHA256: digest)
        #expect(marker.matchesSidecar(sidecar))
        #expect(!marker.matchesSidecar(replacement))
        let legacy = HarcDesktopSpeakerObservationMarker(canonicalRecordingID: canonical,
            sourcePackRevision: nil, decisions: [], acceptedAt: Date())
        #expect(!legacy.matchesSidecar(sidecar))
        let encoded = try JSONEncoder().encode(marker)
        #expect(try JSONDecoder().decode(HarcDesktopSpeakerObservationMarker.self, from: encoded).matchesSidecar(sidecar))
        #expect(throws: (any Error).self) {
            try HarcDesktopClientTransferCoordinator.bindSpeakerObservation(observation(), sidecarSHA256: Data())
        }
    }

    @Test func legacyOperationIDIsUnchanged() throws {
        let id = HarcDesktopClientTransferCoordinator.observationOperationID(
            origin: try origin(), speakerIndex: 3, modelID: "wespeaker_v2", packRevision: try EntityRevision(7))
        #expect(id.description == "7c9b6f22-e881-5255-80a2-be610fd0620f")
    }
    @Test func differentModelsCannotReplayEachOther() throws {
        let source = try origin(), revision = try EntityRevision(7)
        let models = ["wespeaker_v2", "ecapa-revision-a", "ecapa-revision-b"]
        let ids = models.map { model in
            HarcDesktopClientTransferCoordinator.observationOperationID(
                origin: source, speakerIndex: 3, modelID: model, packRevision: revision)
        }
        #expect(Set(ids).count == models.count)
        #expect(ids[1] == HarcDesktopClientTransferCoordinator.observationOperationID(
            origin: source, speakerIndex: 3, modelID: models[1], packRevision: revision))
    }
}


@Suite("Host speaker observation model identity")
struct HarcHostSpeakerObservationIdentityTests {
    private let canonicalID = CanonicalRecordingID(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)

    @Test func hostGenerationAndRecognitionRevisionSeparateRetries() throws {
        let row = SpeakerEmbeddingRow(speakerIndex: 0, vector: [1, 0], totalMs: 6000, segmentCount: 1)
        let digest = Data(repeating: 1, count: 32)
        let revision = try EntityRevision(7)
        func build(_ value: SpeakerEmbeddingRow = row, evidence: Data = digest,
                   pack: EntityRevision = revision) throws -> SpeakerEmbeddingObservation {
            try HarcHostProcessingWorker.speakerObservation(value, canonicalID: canonicalID,
                evidenceSHA256: evidence, packRevision: pack)
        }
        let first = try build()
        #expect(try build() == first)
        #expect(first.sourcePackRevision == revision)
        #expect(try build(evidence: Data(repeating: 2, count: 32)).operationID != first.operationID)
        #expect(try build(pack: EntityRevision(8)).operationID != first.operationID)
        var changed = row; changed.vector = [0, 1]
        #expect(try build(changed).operationID != first.operationID)
        changed = row; changed.totalMs = 7000
        #expect(try build(changed).operationID != first.operationID)
        #expect(throws: (any Error).self) { try build(evidence: Data()) }
        #expect(throws: (any Error).self) {
            try HarcHostProcessingWorker.speakerObservation(row, canonicalID: canonicalID, evidenceSHA256: digest)
        }
    }

    @Test func observationRetainsModelAndSeparatesReplay() throws {
        let models = ["wespeaker_v2", "ecapa-revision-a", "ecapa-revision-b"]
        let observations = try models.map { model in
            try HarcHostProcessingWorker.speakerObservation(
                SpeakerEmbeddingRow(speakerIndex: 3, vector: [1, 0, 0],
                    totalMs: 3000, segmentCount: 2, modelID: model), canonicalID: canonicalID)
        }
        #expect(observations.map(\.modelID) == models)
        #expect(Set(observations.map(\.operationID)).count == models.count)
        #expect(observations[1].operationID == HarcHostProcessingWorker.observationOperationID(
            canonicalID: canonicalID, speakerIndex: 3, modelID: models[1]))
        #expect(observations.allSatisfy { $0.speechDurationMs == 3000 && $0.segmentCount == 2 && $0.speakerIndex == 3 })
        #expect(observations[0].operationID.description == "44a3db2d-6141-5e69-9502-b9ad7a42132b")
    }

    @Test func invalidEvidenceThrowsWithoutIntegerTrap() {
        for (index, duration, count) in [(Int.max, 3000, 2), (3, -1, 2), (3, 3000, Int.max)] {
            #expect(throws: (any Error).self) {
                try HarcHostProcessingWorker.speakerObservation(
                    SpeakerEmbeddingRow(speakerIndex: index, vector: [1, 0, 0],
                        totalMs: duration, segmentCount: count, modelID: "wespeaker_v2"), canonicalID: canonicalID)
            }
        }
    }
}

@Suite("Host immutable speaker evidence")
struct HarcHostSpeakerEvidenceTests {
    @Test func snapshotsBindExactPublicationAndProducer() throws {
        let canonical = CanonicalRecordingID.random()
        let pcm = try CanonicalPCMHash(Data(repeating: 1, count: 32))
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        let result = TranscribeResult(text: "hello", words: [],
            speakers: [.init(speaker: 3, startMs: 0, endMs: 6000)],
            speakerEmbeddings: [.init(speakerIndex: 3, vector: [1, 0], totalMs: 6000, segmentCount: 1, modelID: "wespeaker_v2")], processingMs: 1)
        func snapshots(_ bytes: Data, producerID: DeviceID? = nil) throws -> [SpeakerEvidenceSnapshot] {
            try HarcHostProcessingWorker.speakerEvidenceSnapshots(result, canonicalID: canonical,
                canonicalPCMHash: pcm, producerDeviceID: producerID ?? producer, structuredTranscriptData: bytes)
        }
        let first = try #require(snapshots(Data("artifact-a".utf8)).first)
        #expect(first.producerDeviceID == producer)
        #expect(first.canonicalPCMHash == pcm)
        #expect(first.localClusterID == "host-speaker-3")
        #expect(first.modelID == "wespeaker_v2")
        #expect(try snapshots(Data("artifact-a".utf8)).first == first)
        #expect(try snapshots(Data("artifact-b".utf8)).first?.evidenceSHA256 != first.evidenceSHA256)
        #expect(try snapshots(Data("artifact-a".utf8), producerID: DeviceID(Data(repeating: 4, count: 32))).first?.evidenceSHA256 != first.evidenceSHA256)
    }

    @Test func absentOrInvalidClusterCannotRetainEvidence() throws {
        for index in [-1, 4] {
            let result = TranscribeResult(text: "", words: [], speakers: [.init(speaker: 3, startMs: 0, endMs: 6000)],
                speakerEmbeddings: [.init(speakerIndex: index, vector: [1, 0], totalMs: 6000, segmentCount: 1)], processingMs: 1)
            #expect(throws: (any Error).self) {
                try HarcHostProcessingWorker.speakerEvidenceSnapshots(result, canonicalID: .random(),
                    canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)),
                    producerDeviceID: DeviceID(Data(repeating: 2, count: 32)), structuredTranscriptData: Data())
            }
        }
    }
}

@Suite("Standalone speaker generation binding")
struct HarcStandaloneSpeakerGenerationTests {
    @Test func newDiarizationCannotCarryAnOldExplicitWordIdentity() throws {
        let word = Word(text: "preserved", startMs: 0, endMs: 100,
            speakerAttribution: try WordSpeakerAttribution(speakerIndex: 9))
        var original = SessionTranscript(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/fixture.wav",
            joinedText: "preserved", words: [word], speakers: [], chunks: [])
        original.attributedUtterances = [try AttributedTranscriptUtterance(text: "preserved", startMs: 0,
            endMs: 100, speakerAttribution: try WordSpeakerAttribution(speakerIndex: 9), words: [word])]
        let restored = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        let result = DiarizeResult(segments: [.init(speaker: 0, startMs: 0, endMs: 100)],
            speakers: [], processingMs: 1)
        let changed = HarcStandaloneSpeakerGeneration.applying(result, to: original)
        #expect(changed.attributedUtterances?.first?.text == "preserved")
        #expect(changed.attributedUtterances?.first?.speakerAttribution == nil)
        #expect(changed.attributedUtterances?.first?.words.first?.speakerAttribution == nil)
        #expect(changed.words[0].text == word.text)
        #expect(changed.words[0].startMs == word.startMs)
        #expect(changed.words[0].speakerAttribution == nil)
        #expect(changed.words[0].resolvedSpeakerIndex(in: changed.speakers) == 0)
    }

    @Test func reidentificationReplacesTimelineWithoutDiscardingManualTextOrWords() throws {
        let oldTurn = SpeakerSegment(speaker: 0, startMs: 0, endMs: 6000)
        let words = [Word(text: "reviewed", startMs: 100, endMs: 700)]
        let original = HarcClient.SessionTranscript(startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 6), audioPath: "/tmp/master.wav", joinedText: "Manually corrected text",
            words: words, speakers: [oldTurn], chunks: [.init(startMs: 0, endMs: 6000,
                text: "diagnostic chunk", words: words, speakers: [oldTurn], processingMs: 1)],
            manualEditAt: Date(timeIntervalSince1970: 10))
        var result = DiarizeResult(segments: [.init(speaker: 1, startMs: 0, endMs: 6000)],
            speakers: [.init(speakerIndex: 1, vector: [0, 1], totalMs: 6000, segmentCount: 1)], processingMs: 1)
        result.overlapRanges = []
        let updated = HarcStandaloneSpeakerGeneration.applying(result, to: original)
        #expect(updated.speakers == result.segments)
        #expect(updated.overlapRanges == result.overlapRanges)
        #expect(updated.joinedText == original.joinedText)
        #expect(updated.manualEditAt == original.manualEditAt)
        #expect(updated.words == original.words)
        #expect(updated.chunks.first?.words == original.chunks.first?.words)
        #expect(updated.chunks.first?.speakers.isEmpty == true)
        #expect(original.chunks.first?.speakers == [oldTurn])
    }

    @Test func preparationHashesCanonicalPCMWithoutChangingTheMaster() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-voice-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("canonical.wav")
        let pcm = Data(repeating: 0, count: 192000)
        var wav = Data("RIFF".utf8)
        func append32(_ value: UInt32) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append32(UInt32(pcm.count + 36)); wav.append(Data("WAVEfmt ".utf8)); append32(16)
        wav.append(contentsOf: [1, 0, 1, 0]); append32(16000); append32(32000)
        wav.append(contentsOf: [2, 0, 16, 0]); wav.append(Data("data".utf8)); append32(UInt32(pcm.count)); wav.append(pcm)
        try wav.write(to: url)
        let transcript = HarcClient.SessionTranscript(startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 6), audioPath: url.path, joinedText: "", words: [],
            speakers: [.init(speaker: 0, startMs: 0, endMs: 6000)], chunks: [])
        let canonical = CanonicalRecordingID.random()
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        func prepare(expectedAudio: HarcStandaloneAudioIdentity? = nil) throws -> HarcStandaloneSpeakerGeneration {
            try HarcStandaloneSpeakerGeneration.prepare(transcript: transcript,
                embeddings: [.init(speakerIndex: 0, vector: [1, 0], totalMs: 6000, segmentCount: 1)],
                canonicalID: canonical, producerDeviceID: producer, expectedAudio: expectedAudio)
        }
        let identity = try HarcStandaloneAudioIdentity.capture(url)
        let originalWAV = wav
        let first = try prepare(expectedAudio: identity)
        #expect(first.canonicalFrames == 96000)
        #expect(first.canonicalPCMHash.rawBytes == Data(CryptoKit.SHA256.hash(data: pcm)))
        #expect(try Data(contentsOf: url) == wav)
        wav[wav.count - 1] = 1; try wav.write(to: url)
        #expect(throws: (any Error).self) { try prepare(expectedAudio: identity) }
        let second = try prepare()
        #expect(second.canonicalPCMHash != first.canonicalPCMHash)
        #expect(second.snapshots.first?.evidenceSHA256 != first.snapshots.first?.evidenceSHA256)
        #expect(second.structuredTranscriptData == first.structuredTranscriptData)
        try originalWAV.write(to: url, options: .atomic)
        let restored = try HarcStandaloneAudioIdentity.capture(url)
        #expect(restored.hash == identity.hash)
        #expect(restored != identity, "Replacing a file with identical bytes still invalidates in-flight inference")
        #expect(throws: (any Error).self) { try prepare(expectedAudio: identity) }
        let link = root.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try HarcStandaloneAudioIdentity.capture(link) }
    }

    @Test func generationBindsExactTranscriptAndRejectsMismatchedVoice() throws {
        let canonical = CanonicalRecordingID.random()
        let hash = try CanonicalPCMHash(Data(repeating: 1, count: 32))
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        let transcript = HarcClient.SessionTranscript(startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 7), audioPath: "/tmp/protected.wav", joinedText: "reviewed words",
            words: [], speakers: [.init(speaker: 0, startMs: 0, endMs: 6000)], chunks: [], manualEditAt: Date(timeIntervalSince1970: 8))
        let voice = HarcCore.SpeakerEmbeddingRow(speakerIndex: 0, vector: [1, 0], totalMs: 6000, segmentCount: 1)
        func build(_ value: HarcClient.SessionTranscript, _ rows: [HarcCore.SpeakerEmbeddingRow]) throws -> HarcStandaloneSpeakerGeneration {
            try HarcStandaloneSpeakerGeneration.build(transcript: value, embeddings: rows,
                canonicalID: canonical, producerDeviceID: producer, canonicalPCMHash: hash, canonicalFrames: 96000)
        }
        let generation = try build(transcript, [voice])
        let snapshot = try #require(generation.snapshots.first)
        #expect(snapshot.localClusterID == "local-speaker-0")
        #expect(snapshot.processingArtifactSHA256 == Data(CryptoKit.SHA256.hash(data: generation.structuredTranscriptData)))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(HarcClient.SessionTranscript.self, from: generation.structuredTranscriptData) == transcript)
        var changed = transcript; changed.joinedText = "changed words"
        #expect(try build(changed, [voice]).snapshots.first?.evidenceSHA256 != snapshot.evidenceSHA256)
        for rows in [[voice, voice], [.init(speakerIndex: 1, vector: [1, 0], totalMs: 6000, segmentCount: 1)],
                     [.init(speakerIndex: 0, vector: [1, 0], totalMs: 6001, segmentCount: 1)]] {
            #expect(throws: (any Error).self) { try build(transcript, rows) }
        }
        changed = transcript; changed.speakers.append(.init(speaker: 0, startMs: 1000, endMs: 2000))
        #expect(throws: (any Error).self) { try build(changed, [voice]) }
        changed = transcript; changed.speakers = [.init(speaker: 0, startMs: 0, endMs: 6001)]
        #expect(throws: (any Error).self) { try build(changed, [voice]) }
    }
}
