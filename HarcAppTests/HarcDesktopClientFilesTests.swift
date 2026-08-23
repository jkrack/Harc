import CryptoKit
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import Testing
@testable import Harc

@Suite("Desktop Client durable capture files")
struct HarcDesktopClientFilesTests {
    @Test("Canonical WAV is copied, normalized, and hashed")
    func canonicalizesWAV() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pcm = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        try makeWAV(pcm: pcm).write(to: fixture.source)

        let prepared = try HarcDesktopClientFiles.canonicalizeWAV(
            source: fixture.source,
            destination: fixture.destination
        )

        #expect(prepared.frames == 3)
        #expect(prepared.pcmSHA256 == Data(SHA256.hash(data: pcm)))
        let output = try Data(contentsOf: fixture.destination)
        #expect(output.count == 44 + pcm.count)
        #expect(output.prefix(4) == Data("RIFF".utf8))
        #expect(output[8 ..< 12] == Data("WAVE".utf8))
        #expect(output.suffix(pcm.count) == pcm)
    }

    @Test("Noncanonical WAV is rejected without publishing a destination")
    func rejectsNoncanonicalWAV() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not a wave file".utf8).write(to: fixture.source)

        do {
            _ = try HarcDesktopClientFiles.canonicalizeWAV(
                source: fixture.source,
                destination: fixture.destination
            )
            Issue.record("Expected invalid WAV rejection")
        } catch HarcDesktopClientError.invalidWAV {
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        }
    }

    @Test("An existing durable destination is never overwritten")
    func refusesOverwrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeWAV(pcm: Data([0, 0])).write(to: fixture.source)
        let sentinel = Data("owned".utf8)
        try sentinel.write(to: fixture.destination)

        do {
            _ = try HarcDesktopClientFiles.canonicalizeWAV(
                source: fixture.source,
                destination: fixture.destination
            )
            Issue.record("Expected exclusive-create rejection")
        } catch HarcDesktopClientError.destinationExists {
            #expect(try Data(contentsOf: fixture.destination) == sentinel)
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "harc-desktop-client-files-\(UUID().uuidString)",
                isDirectory: true
            )
            source = root.appendingPathComponent("source.wav")
            destination = root.appendingPathComponent("destination.wav")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
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

@Suite("Desktop Host pairing-repair classification")
struct HarcDesktopPairingRepairClassificationTests {
    @Test("durable adoption and authenticated grant rejection require repair")
    func durableTrustFailuresRequireRepair() {
        #expect(
            HarcDesktopHostSessionConnector.requiresPairingRepair(
                HarcPersistedAdoptionValidationError.grantExpired
            )
        )
        #expect(
            HarcDesktopHostSessionConnector.requiresPairingRepair(
                HarcBootstrapClientError.sessionGrantUnavailable
            )
        )
        #expect(
            HarcDesktopHostSessionConnector.requiresPairingRepair(
                HarcBootstrapClientError.grantBindingMismatch(
                    field: "sessionGrantContinuity"
                )
            )
        )
    }

    @Test("ordinary route and availability errors remain retryable")
    func reachabilityFailuresRemainRetryable() {
        #expect(
            !HarcDesktopHostSessionConnector.requiresPairingRepair(
                URLError(.networkConnectionLost)
            )
        )
        #expect(
            !HarcDesktopHostSessionConnector.requiresPairingRepair(
                HarcBootstrapClientError.invalidResponse(field: "hostInfo")
            )
        )
    }

    @Test("only pairing repair stops periodic authenticated probes")
    func onlyPairingRepairIsTerminal() {
        #expect(
            HarcDesktopClientTransferCoordinator.probeIsTerminal(
                .pairingRepairRequired("repair")
            )
        )
        #expect(
            !HarcDesktopClientTransferCoordinator.probeIsTerminal(
                .unavailable("offline")
            )
        )
        #expect(
            !HarcDesktopClientTransferCoordinator.probeIsTerminal(.reachable)
        )
    }
}

@Suite("Desktop Client automatic retry schedule")
struct HarcDesktopRetryScheduleTests {
    @Test("recoverable failures back off to a bounded five-minute ceiling")
    func boundedBackoff() {
        let now = Date(timeIntervalSince1970: 1_000)
        var schedule = HarcDesktopRetrySchedule()
        let expected: [TimeInterval] = [1, 2, 5, 10, 30, 60, 120, 300, 300]

        for delay in expected {
            #expect(
                schedule.recordFailure(now: now, jitterMultiplier: 1)
                    == delay
            )
            #expect(schedule.nextRetryAt == now.addingTimeInterval(delay))
        }
        #expect(schedule.consecutiveFailures == 8)
    }

    @Test("retry state round-trips and a success fully resets it")
    func persistenceAndReset() throws {
        var schedule = HarcDesktopRetrySchedule()
        _ = schedule.recordFailure(
            now: Date(timeIntervalSince1970: 2_000),
            jitterMultiplier: 1
        )
        let restored = try JSONDecoder().decode(
            HarcDesktopRetrySchedule.self,
            from: JSONEncoder().encode(schedule)
        )
        #expect(restored == schedule)

        schedule.reset()
        #expect(schedule.consecutiveFailures == 0)
        #expect(schedule.nextRetryAt == nil)
    }

    @Test("a relaunch honors the persisted retry deadline")
    func persistedDeadline() {
        let failureAt = Date(timeIntervalSince1970: 3_000)
        var schedule = HarcDesktopRetrySchedule()
        _ = schedule.recordFailure(now: failureAt, jitterMultiplier: 1)

        #expect(
            schedule.remainingDelay(
                at: failureAt.addingTimeInterval(0.25)
            ) == 0.75
        )
        #expect(
            schedule.remainingDelay(
                at: failureAt.addingTimeInterval(2)
            ) == 0
        )
        schedule.reset()
        #expect(schedule.remainingDelay(at: failureAt) == nil)
    }

    @Test("derived Host work keeps automatic retry alive after audio commits")
    func derivedWorkKeepsRetryAlive() {
        #expect(!HarcDesktopClientTransferCoordinator.hasPendingWork(
            recordings: 0,
            processing: 0,
            speakers: 0
        ))
        #expect(HarcDesktopClientTransferCoordinator.hasPendingWork(
            recordings: 0,
            processing: 1,
            speakers: 0
        ))
        #expect(HarcDesktopClientTransferCoordinator.hasPendingWork(
            recordings: 0,
            processing: 0,
            speakers: 1
        ))
    }
}

@Suite("Host processing work admission")
struct HarcHostWorkAdmissionPolicyTests {
    @Test("Host processing retries transient failures with bounded backoff")
    func boundedProcessingRetry() {
        #expect(HarcHostProcessingRetryPolicy.delay(afterFailureCount: 1) == 5)
        #expect(HarcHostProcessingRetryPolicy.delay(afterFailureCount: 2) == 15)
        #expect(HarcHostProcessingRetryPolicy.delay(afterFailureCount: 99) == 3_600)
    }

    @Test("idle healthy Host accepts derived work")
    func acceptsSpareCycles() {
        let decision = HarcHostWorkAdmissionPolicy.decide(
            HarcHostWorkAdmissionSnapshot(
                thermalPressure: .nominal,
                lowPowerModeEnabled: false,
                oneMinuteLoad: 1,
                activeProcessorCount: 8,
                harcCaptureActive: false
            )
        )
        #expect(decision == .run)
    }

    @Test(
        "thermal pressure, low power, and saturated CPUs defer without failing work",
        arguments: [
            HarcHostWorkAdmissionSnapshot(
                thermalPressure: .serious,
                lowPowerModeEnabled: false,
                oneMinuteLoad: 0,
                activeProcessorCount: 8,
                harcCaptureActive: false
            ),
            HarcHostWorkAdmissionSnapshot(
                thermalPressure: .nominal,
                lowPowerModeEnabled: true,
                oneMinuteLoad: 0,
                activeProcessorCount: 8,
                harcCaptureActive: false
            ),
            HarcHostWorkAdmissionSnapshot(
                thermalPressure: .fair,
                lowPowerModeEnabled: false,
                oneMinuteLoad: 6,
                activeProcessorCount: 8,
                harcCaptureActive: false
            ),
            HarcHostWorkAdmissionSnapshot(
                thermalPressure: .nominal,
                lowPowerModeEnabled: false,
                oneMinuteLoad: 0,
                activeProcessorCount: 8,
                harcCaptureActive: true
            ),
        ]
    )
    func defersBusyHost(_ snapshot: HarcHostWorkAdmissionSnapshot) {
        guard case .deferFor(let delay, _) =
            HarcHostWorkAdmissionPolicy.decide(snapshot) else {
            Issue.record("Expected work deferral")
            return
        }
        #expect(delay >= 30)
    }
}

@Suite("Desktop speaker decision evidence")
struct HarcDesktopSpeakerDecisionEvidenceTests {
    @Test("non-matches remain durable review concerns")
    func reviewConcernPersists() throws {
        let decision = try SpeakerObservationDecision(
            operationID: .random(),
            disposition: .noMatch,
            personID: nil,
            displayName: nil,
            score: nil,
            recognitionPackRevision: .initial,
            recordingRevision: .initial
        )
        let marker = HarcDesktopSpeakerObservationMarker(
            canonicalRecordingID: .random(),
            sourcePackRevision: .initial,
            decisions: [
                HarcDesktopSpeakerDecisionRecord(
                    speakerIndex: 0,
                    decision: decision
                ),
            ],
            acceptedAt: Date(timeIntervalSince1970: 3_000)
        )
        let restored = try JSONDecoder().decode(
            HarcDesktopSpeakerObservationMarker.self,
            from: JSONEncoder().encode(marker)
        )
        #expect(restored.concernCount == 1)
        #expect(restored.decisions?.first?.decision == decision)
        #expect(restored.sourcePackRevision == .initial)
    }

    @Test("unresolved speakers are reconsidered on a bounded schedule")
    func unresolvedSpeakerReviewSchedule() throws {
        let acceptedAt = Date(timeIntervalSince1970: 4_000)
        let reviewAt = acceptedAt.addingTimeInterval(6 * 60 * 60)
        let decision = try SpeakerObservationDecision(
            operationID: .random(),
            disposition: .pendingReview,
            personID: nil,
            displayName: nil,
            score: nil,
            recognitionPackRevision: .initial,
            recordingRevision: .initial
        )
        let marker = HarcDesktopSpeakerObservationMarker(
            canonicalRecordingID: .random(),
            sourcePackRevision: .initial,
            decisions: [
                HarcDesktopSpeakerDecisionRecord(
                    speakerIndex: 0,
                    decision: decision
                ),
            ],
            acceptedAt: acceptedAt,
            nextReviewAt: reviewAt
        )

        #expect(!marker.needsReview(at: reviewAt.addingTimeInterval(-1)))
        #expect(marker.needsReview(at: reviewAt))
    }

    @Test("legacy acceptance markers remain readable")
    func legacyMarkerDecodes() throws {
        let canonicalID = CanonicalRecordingID.random()
        let json: [String: Any] = [
            "canonicalRecordingID": canonicalID.description,
            "acceptedAt": 0,
        ]
        let decoded = try JSONDecoder().decode(
            HarcDesktopSpeakerObservationMarker.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.canonicalRecordingID == canonicalID)
        #expect(decoded.decisions == nil)
        #expect(decoded.concernCount == 0)
        #expect(decoded.hostBinding == nil)
    }

    @Test("completion evidence is valid only for its adopted Host")
    func completionEvidenceIsHostBound() throws {
        let first = AdoptedTrustTuple(
            libraryID: .random(),
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x11, count: HostAuthorityID.byteCount))
        )
        let second = AdoptedTrustTuple(
            libraryID: .random(),
            hostAuthorityID: try HostAuthorityID(Data(repeating: 0x22, count: HostAuthorityID.byteCount))
        )
        let binding = HarcDesktopHostEvidenceBinding(trust: first)

        #expect(binding.matches(first))
        #expect(!binding.matches(second))
        #expect(!binding.matches(Optional<AdoptedTrustTuple>.none))
    }
}
