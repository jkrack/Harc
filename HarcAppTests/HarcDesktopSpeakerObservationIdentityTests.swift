import Foundation
import Darwin
import HarcHost
import HarcProtocol
@testable import HarcStore
import GRDB
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


@Suite("Host processing request refresh")
struct HarcHostProcessingRequestValidationTests {
    @Test func refreshAcceptsOnlyCtimeDrift() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let stale = try fixture.request(ctimeOffset: -1)
        let fresh = try fixture.request()
        let calls = RefreshCalls()
        let result = try await HarcHostProcessingRequestValidation.refresh(stale) { id in
            await calls.record()
            #expect(id == fresh.canonicalRecordingID)
            return fresh
        }
        #expect(result == fresh)
        #expect(await calls.count == 1)
    }

    @Test func resourceDeferralPassesThroughWithoutImmediateRetry() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let calls = RefreshCalls()
        await #expect(throws: HostCanonicalResourceDeferred.insufficientCapacity) {
            _ = try await HarcHostProcessingRequestValidation.refresh(fixture.request()) { _ in
                await calls.record()
                throw HostCanonicalResourceDeferred.insufficientCapacity
            }
        }
        #expect(await calls.count == 1)
    }

    @Test func callbackFailureNeverFallsBackOrRetries() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let calls = RefreshCalls()
        await #expect(throws: (any Error).self) {
            _ = try await HarcHostProcessingRequestValidation.refresh(fixture.request()) { _ in
                await calls.record()
                throw RefreshFailure.integrity
            }
        }
        #expect(await calls.count == 1)
    }

    @Test func readRaceRestartsFullValidation() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let fresh = try fixture.request()
        let calls = RefreshCalls()
        let result = try await HarcHostProcessingRequestValidation.refresh(fresh) { _ in
            await calls.record()
            if await calls.count == 1 { throw StoreError.canonicalArtifactIdentityMismatch }
            return fresh
        }
        #expect(result == fresh)
        #expect(await calls.count == 2)
    }

    @Test func persistentReadRacePreservesTypedFailureAndStops() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let calls = RefreshCalls()
        await #expect(throws: StoreError.canonicalArtifactIdentityMismatch) {
            _ = try await HarcHostProcessingRequestValidation.refresh(fixture.request()) { _ in
                await calls.record()
                throw StoreError.canonicalArtifactIdentityMismatch
            }
        }
        #expect(await calls.count == 2)
    }

    @Test func contentAndStableIdentityFailuresAreTerminal() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        for failure in [HarcHostError.canonicalHashMismatch, .canonicalArtifactIdentityMismatch] {
            let calls = RefreshCalls()
            await #expect(throws: (any Error).self) {
                _ = try await HarcHostProcessingRequestValidation.refresh(fixture.request()) { _ in
                    await calls.record()
                    throw failure
                }
            }
            #expect(await calls.count == 1)
        }
    }

    @Test func validationPreservesSafeOriginalCauseWithoutChangingTerminalPolicy() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let cases: [(any Error, HarcHostProcessingDiagnostic.Cause)] = [
            (HarcHostError.canonicalHashMismatch, .hostCanonicalHashMismatch),
            (HarcHostError.canonicalArtifactIdentityMismatch, .hostCanonicalArtifactIdentityMismatch),
            (HarcHostError.publicationIO("SYNTHETIC-SECRET"), .hostPublicationIO),
            (HarcProtocolCodecError.invalidSignature, .protocolInvalidSignature),
            (StoreError.readFailed("SYNTHETIC-SECRET"), .storeReadFailed),
            (RefreshFailure.integrity, .unknown),
            (CancellationError(), .cancelled)
        ]
        for (failure, expected) in cases {
            let calls = RefreshCalls()
            do {
                _ = try await HarcHostProcessingRequestValidation.refresh(fixture.request()) { _ in
                    await calls.record()
                    throw failure
                }
                Issue.record("Expected revalidation failure")
            } catch {
                #expect(HarcHostProcessingDiagnostic.Cause.classify(error) == expected)
                #expect(!HarcHostProcessingWorker.isAutomaticallyRetryable(error))
                #expect(error is HostProcessingWorkerError)
            }
            #expect(await calls.count == 1)
        }
    }

    @Test func strictRaceHasOnlyOneImmediateRetry() async throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let stale = try fixture.request(ctimeOffset: -1)
        let calls = RefreshCalls()
        await #expect(throws: (any Error).self) {
            _ = try await HarcHostProcessingRequestValidation.refresh(stale) { _ in
                await calls.record()
                return stale
            }
        }
        #expect(await calls.count == 2)
    }

    @Test func rejectsChangedCanonicalAndSafeIdentityFields() throws {
        let fixture = try RefreshFixture()
        defer { fixture.remove() }
        let original = try fixture.request()
        let identity = original.artifactIdentity
        let identities = try [
            fixture.identity(device: identity.deviceNumber + 1),
            fixture.identity(inode: identity.inodeNumber + 1),
            fixture.identity(owner: identity.ownerUserID + 1),
            fixture.identity(mode: UInt32(S_IFREG) | 0o400)
        ]
        var changed = try identities.map { identity in
            try HostDurableProcessingRequest(canonicalRecordingID: original.canonicalRecordingID,
                canonicalWAVURL: original.canonicalWAVURL, canonicalPCMHash: original.canonicalPCMHash,
                canonicalPCMFrames: 1, artifactIdentity: identity)
        }
        changed.append(try HostDurableProcessingRequest(canonicalRecordingID: .random(),
            canonicalWAVURL: original.canonicalWAVURL, canonicalPCMHash: original.canonicalPCMHash,
            canonicalPCMFrames: 1, artifactIdentity: identity))
        changed.append(try HostDurableProcessingRequest(canonicalRecordingID: original.canonicalRecordingID,
            canonicalWAVURL: original.canonicalWAVURL, canonicalPCMHash: CanonicalPCMHash(Data(repeating: 2, count: 32)),
            canonicalPCMFrames: 1, artifactIdentity: identity))
        changed.append(try HostDurableProcessingRequest(canonicalRecordingID: original.canonicalRecordingID,
            canonicalWAVURL: original.canonicalWAVURL.appendingPathExtension("replacement"), canonicalPCMHash: original.canonicalPCMHash,
            canonicalPCMFrames: 1, artifactIdentity: identity))
        for request in changed {
            #expect(throws: (any Error).self) {
                try HarcHostProcessingRequestValidation.requireSameBinding(original, request)
            }
        }
    }
}

private enum RefreshFailure: Error { case integrity }
private actor RefreshCalls {
    var count = 0
    func record() { count += 1 }
}
private struct RefreshFixture: Sendable {
    let url: URL
    let canonicalID = CanonicalRecordingID.random()
    let snapshot: HostCanonicalArtifactIdentity

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("host-refresh-" + UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 46).write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw RefreshFailure.integrity }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RefreshFailure.integrity }
        defer { close(fd) }
        snapshot = try HostCanonicalArtifactIdentity(validatingOpenFileDescriptor: fd, boundTo: url)
    }

    func identity(device: UInt64? = nil, inode: UInt64? = nil, owner: UInt32? = nil,
                  mode: UInt32? = nil, ctimeOffset: Int64 = 0) throws -> HostCanonicalArtifactIdentity {
        try HostCanonicalArtifactIdentity(deviceNumber: device ?? snapshot.deviceNumber,
            inodeNumber: inode ?? snapshot.inodeNumber, ownerUserID: owner ?? snapshot.ownerUserID,
            posixMode: mode ?? snapshot.posixMode, linkCount: snapshot.linkCount,
            fileByteCount: snapshot.fileByteCount, changeTimeSeconds: snapshot.changeTimeSeconds + ctimeOffset,
            changeTimeNanoseconds: snapshot.changeTimeNanoseconds)
    }
    func request(ctimeOffset: Int64 = 0) throws -> HostDurableProcessingRequest {
        try HostDurableProcessingRequest(canonicalRecordingID: canonicalID, canonicalWAVURL: url,
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)), canonicalPCMFrames: 1,
            artifactIdentity: identity(ctimeOffset: ctimeOffset))
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}


@Suite("Host processing worker metadata races")
struct HarcHostProcessingWorkerMetadataTests {
    @Test func resourceDeferralDoesNoExpensiveWorkUntilAllowed() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 0, initiallyAllowed: false)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.signal(fixture.request, isRecovery: true)
        await fixture.probe.waitForAdmissions(2)
        #expect(await fixture.probe.preparations == 0)
        #expect(await fixture.probe.validations == 0)
        #expect(await fixture.probe.transcriptions == 0)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .pending)
        await fixture.probe.allowResources()
        await fixture.worker.waitUntilIdle()
        #expect(await fixture.probe.transcriptions == 1)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .ready)
        await fixture.cleanup()
    }

    @Test func metadataRetryMustReadmitBeforeFullValidation() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 1, deferAfterTranscription: true)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.signal(fixture.request)
        await fixture.probe.waitForAdmissions(3)
        #expect(await fixture.probe.preparations == 1)
        #expect(await fixture.probe.validations == 1)
        #expect(await fixture.probe.transcriptions == 1)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .failedRecoverable)
        await fixture.probe.allowResources()
        await fixture.worker.waitUntilIdle()
        #expect(await fixture.probe.transcriptions == 2)
        #expect(await fixture.probe.validations == 2)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .ready)
        await fixture.cleanup()
    }

    @Test func validationTimeResourceDeferralDoesNotMarkTranscribingOrFailure() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 0, deferValidation: true)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.signal(fixture.request)
        await fixture.probe.waitForAdmissions(3)
        #expect(await fixture.probe.validations >= 2)
        #expect(await fixture.probe.transcriptions == 0)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .pending)
        await fixture.probe.allowResources()
        await fixture.worker.waitUntilIdle()
        #expect(await fixture.probe.transcriptions == 1)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .ready)
        await fixture.cleanup()
    }

    @Test func queueWaitsForValidatorAndDiscardsChangedTranscription() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 1)
        await fixture.worker.signal(fixture.request)
        await fixture.worker.waitUntilIdle()
        #expect(await fixture.probe.transcriptions == 0)
        #expect(await fixture.probe.preparations == 0)
        #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing.state == .pending)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.waitUntilIdle()
        let row = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(await fixture.probe.transcriptions == 2)
        #expect(await fixture.probe.validations == 2)
        #expect(row.processing.state == .ready)
        #expect(row.transcriptText?.contains("attempt 2") == true)
        #expect(row.transcriptText?.contains("attempt 1") == false)
        await fixture.cleanup()
    }

    @Test func repeatedDriftExhaustsVerifiedRetriesWithoutPublishing() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 10)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.signal(fixture.request)
        await fixture.worker.waitUntilIdle()
        let row = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(await fixture.probe.transcriptions == 3)
        #expect(await fixture.probe.validations == 3)
        #expect(row.processing.state == .failedRecoverable)
        #expect(row.processing.failure?.code == "host.processing.audio_after_transcription.store.canonical_artifact_identity_mismatch")
        #expect(row.transcriptText == nil)
        #expect(try await fixture.store.hostSpeakerProcessingOutcome(recordingID: fixture.recordingID) == nil)
        await fixture.cleanup()
    }

    @Test func transientDaemonFailuresRetainTheirPhaseAndStillRetry() async throws {
        for prepareFailure in [true, false] {
            let fixture = try await WorkerRefreshFixture.make(drifts: 0,
                preparationError: prepareFailure ? .daemonLaunchFailed("SYNTHETIC-SECRET") : nil,
                transcriptionError: prepareFailure ? nil : .transcribeFailed(code: "model_not_loaded", message: "SYNTHETIC-SECRET"))
            await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
            await fixture.worker.signal(fixture.request)
            let deadline = Date().addingTimeInterval(3)
            var failure: ProcessingFailure?
            while Date() < deadline {
                failure = try await fixture.store.fetch(id: fixture.recordingID)?.processing.failure
                if failure != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(failure?.code == (prepareFailure
                ? "host.processing.daemon_preparation.client.daemon_launch_failed"
                : "host.processing.transcription.daemon.model_not_loaded"))
            await fixture.worker.waitUntilIdle()
            #expect(await fixture.probe.preparations == 2)
            #expect(await fixture.probe.transcriptions == (prepareFailure ? 1 : 2))
            #expect(try await fixture.store.fetch(id: fixture.recordingID)?.processing == .ready)
            await fixture.cleanup()
        }
    }

    @Test func typedValidationFailurePersistsAcrossStoreReopenAndRetryCanSucceed() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 0, onDisk: true)
        await fixture.worker.installRequestValidator { _ in
            throw HarcHostError.publicationRecoveryRequired("SYNTHETIC-SECRET")
        }
        await fixture.worker.signal(fixture.request)
        await fixture.worker.waitUntilIdle()
        let expected = HarcHostProcessingDiagnostic(phase: .canonicalValidation,
            cause: .hostPublicationRecoveryRequired).failure
        let reopened = try await RecordingStore.onDisk(url: fixture.root.appendingPathComponent("diagnostic.sqlite"))
        #expect(try await reopened.fetch(id: fixture.recordingID)?.processing.failure == expected)
        #expect(await fixture.probe.transcriptions == 0)
        await fixture.worker.installRequestValidator { try await fixture.probe.validate($0) }
        await fixture.worker.signal(fixture.request)
        await fixture.worker.waitUntilIdle()
        #expect(try await reopened.fetch(id: fixture.recordingID)?.processing == .ready)
        #expect(await fixture.probe.transcriptions == 1)
        await fixture.cleanup()
    }

    @Test func rejectedEvidenceNeverInvokesTranscription() async throws {
        let fixture = try await WorkerRefreshFixture.make(drifts: 0)
        let calls = RefreshCalls()
        await fixture.worker.installRequestValidator { _ in
            await calls.record()
            throw HarcHostError.canonicalHashMismatch
        }
        await fixture.worker.signal(fixture.request)
        await fixture.worker.waitUntilIdle()
        #expect(await calls.count == 1)
        #expect(await fixture.probe.transcriptions == 0)
        let row = try #require(try await fixture.store.fetch(id: fixture.recordingID))
        #expect(row.processing.state == .failedRecoverable)
        #expect(row.processing.failure?.code == "host.processing.canonical_validation.host.canonical_hash_mismatch")
        await fixture.cleanup()
    }
}

private actor WorkerRefreshProbe {
    let original: HostDurableProcessingRequest
    let bytes: Data
    let drifts: Int
    let preparationError: ClientError?
    let transcriptionError: ClientError?
    var preparations = 0
    var transcriptions = 0
    var validations = 0
    var admissions = 0
    var resourcesAllowed: Bool
    var deferAfterTranscription: Bool
    var deferValidation: Bool

    init(request: HostDurableProcessingRequest, bytes: Data, drifts: Int,
         initiallyAllowed: Bool, deferAfterTranscription: Bool, deferValidation: Bool,
         preparationError: ClientError?, transcriptionError: ClientError?) {
        original = request
        self.bytes = bytes
        self.drifts = drifts
        self.preparationError = preparationError
        self.transcriptionError = transcriptionError
        self.resourcesAllowed = initiallyAllowed
        self.deferAfterTranscription = deferAfterTranscription
        self.deferValidation = deferValidation
    }
    func admit() throws {
        admissions += 1
        guard resourcesAllowed, !(deferAfterTranscription && transcriptions > 0) else {
            throw HostCanonicalResourceDeferred.insufficientCapacity
        }
    }
    func allowResources() {
        resourcesAllowed = true
        deferAfterTranscription = false
        deferValidation = false
    }
    func waitForAdmissions(_ count: Int) async {
        let deadline = Date().addingTimeInterval(12)
        while admissions < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(admissions >= count)
    }
    func prepare() throws -> String {
        preparations += 1
        if preparations == 1, let preparationError { throw preparationError }
        return "test-only-no-socket"
    }
    func validate(_ id: CanonicalRecordingID) throws -> HostDurableProcessingRequest {
        validations += 1
        if deferValidation { throw HostCanonicalResourceDeferred.audioNotResident }
        guard id == original.canonicalRecordingID,
              try Data(contentsOf: original.canonicalWAVURL) == bytes else {
            throw HarcHostError.canonicalHashMismatch
        }
        let fd = open(original.canonicalWAVURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RefreshFailure.integrity }
        defer { close(fd) }
        let fresh = try HostDurableProcessingRequest(canonicalRecordingID: id,
            canonicalWAVURL: original.canonicalWAVURL, canonicalPCMHash: original.canonicalPCMHash,
            canonicalPCMFrames: original.canonicalPCMFrames,
            artifactIdentity: HostCanonicalArtifactIdentity(validatingOpenFileDescriptor: fd, boundTo: original.canonicalWAVURL))
        try HarcHostProcessingRequestValidation.requireSameBinding(original, fresh)
        return fresh
    }
    func transcribe() async throws -> TranscribeResult {
        transcriptions += 1
        if transcriptions == 1, let transcriptionError { throw transcriptionError }
        if transcriptions <= drifts {
            // An unchanged final mode and unchanged bytes, but a new ctime.
            try await Task.sleep(for: .milliseconds(10))
            guard chmod(original.canonicalWAVURL.path, 0o400) == 0,
                  chmod(original.canonicalWAVURL.path, 0o600) == 0 else { throw RefreshFailure.integrity }
        }
        return TranscribeResult(text: "attempt \(transcriptions)", words: [], speakers: [], processingMs: 1)
    }
}

private struct WorkerRefreshFixture: Sendable {
    let root: URL
    let store: RecordingStore
    let recordingID: Int64
    let request: HostDurableProcessingRequest
    let probe: WorkerRefreshProbe
    let worker: HarcHostProcessingWorker

    static func make(drifts: Int, initiallyAllowed: Bool = true,
                     deferAfterTranscription: Bool = false, deferValidation: Bool = false,
                     onDisk: Bool = false, preparationError: ClientError? = nil,
                     transcriptionError: ClientError? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("canonical.wav")
        // Canonical mono Int16, 16 kHz WAV containing one sample.
        let bytes = Data([82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,
                          1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0,100,97,116,97,2,0,0,0,0,0])
        try bytes.write(to: wav)
        guard chmod(wav.path, 0o600) == 0 else { throw RefreshFailure.integrity }
        let fd = open(wav.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RefreshFailure.integrity }
        defer { close(fd) }
        let identity = try HostCanonicalArtifactIdentity(validatingOpenFileDescriptor: fd, boundTo: wav)
        let hash = try CanonicalPCMHash(Data(SHA256.hash(data: bytes.suffix(2))))
        let producer = try DeviceID(Data(repeating: 9, count: 32))
        var recording = Recording(wavPath: wav.path,
            txtPath: root.appendingPathComponent("transcript.md").path,
            jsonPath: root.appendingPathComponent("transcript.json").path,
            startedAt: Date(), endedAt: Date(), title: "Worker fixture", transcriptText: nil)
        recording.processing = .pending
        recording.projection = .pending
        let store = try await onDisk
            ? RecordingStore.onDisk(url: root.appendingPathComponent("diagnostic.sqlite"))
            : RecordingStore.inMemory()
        let inserted = try await store.upsert(recording)
        let recordingID = try #require(inserted.id)
        let database = await store.uncoordinatedDB
        try await database.write { db in
            try db.execute(sql: "UPDATE recordings SET canonical_pcm_sha256 = ?, canonical_pcm_frames = 1, origin_device_id = ?, origin_recording_uuid = ? WHERE id = ?",
                           arguments: [hash.rawBytes, producer.rawBytes, UUID().uuidString.lowercased(), recordingID])
        }
        let request = try HostDurableProcessingRequest(canonicalRecordingID: inserted.canonicalID,
            canonicalWAVURL: wav, canonicalPCMHash: hash, canonicalPCMFrames: 1, artifactIdentity: identity)
        let probe = WorkerRefreshProbe(request: request, bytes: bytes, drifts: drifts,
            initiallyAllowed: initiallyAllowed, deferAfterTranscription: deferAfterTranscription,
            deferValidation: deferValidation, preparationError: preparationError, transcriptionError: transcriptionError)
        let worker = HarcHostProcessingWorker(store: store,
            launcher: DaemonLauncher(binaryURL: root.appendingPathComponent("nonexistent"),
                socketPath: root.appendingPathComponent("unused.sock").path,
                logURL: root.appendingPathComponent("unused.log")),
            producerDeviceID: producer, diarize: false, vad: false, clientArtifactGrace: 0,
            transcription: .init(prepare: { try await probe.prepare() }, run: { _, _, _, _ in try await probe.transcribe() }),
            resourceAdmission: { _ in try await probe.admit() }, resourceDeferralDelay: 0.05,
            admissionSnapshot: {
                HarcHostWorkAdmissionSnapshot(thermalPressure: .nominal, lowPowerModeEnabled: false,
                    oneMinuteLoad: 0, activeProcessorCount: 1, harcCaptureActive: false)
            })
        return Self(root: root, store: store, recordingID: recordingID, request: request, probe: probe, worker: worker)
    }
    func cleanup() async {
        await worker.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
