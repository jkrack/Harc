import Foundation
import HarcDomain
import HarcProtocolWire
import Testing
@testable import HarcProtocol

@Suite("Authenticated Host speaker outcome conversion")
struct HostSpeakerOutcomeConversionTests {
    private let canonical = CanonicalRecordingID.random()
    private func fixture() throws -> (HostSpeakerProcessingOutcome, OriginRecordingID) {
        let producer = try DeviceID(Data(repeating: 2, count: 32))
        return (try HostSpeakerProcessingOutcome(canonicalRecordingID: canonical,
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 1, count: 32)), producerDeviceID: producer,
            processingArtifactSHA256: Data(repeating: 3, count: 32), diarization: .completed,
            clusters: [.init(speakerIndex: 0),
                .init(speakerIndex: 1, evidenceSHA256: Data(repeating: 4, count: 32), decisionOperationID: .random(),
                    disposition: .noMatch, recognitionPackRevision: EntityRevision(7))]),
            OriginRecordingID(deviceID: try DeviceID(Data(repeating: 5, count: 32)), recordingUUID: UUID()))
    }
    private func status(_ outcome: HostSpeakerProcessingOutcome, origin: OriginRecordingID) -> Harc_V1_ProcessingStatusV1 {
        var status = Harc_V1_ProcessingStatusV1()
        status.canonicalRecordingID = .init(outcome.canonicalRecordingID)
        status.originRecordingID = .init(origin)
        status.canonicalAudioSha256.value = outcome.canonicalPCMHash.rawBytes
        status.processing = .init(.ready)
        status.projection = .init(.readyV1)
        status.hostSpeakerOutcome = .init(outcome)
        return status
    }
    @Test func serializedRoundTripPreservesUnknownAndUnmatched() throws {
        let (outcome, origin) = try fixture()
        let wire = status(outcome, origin: origin)
        let decoded = try Harc_V1_ProcessingStatusV1(serializedBytes: wire.serializedData())
        #expect(try decoded.validatedHostSpeakerOutcome(canonicalID: canonical, originID: origin,
            canonicalPCMHash: outcome.canonicalPCMHash, producerDeviceID: outcome.producerDeviceID) == outcome)
        #expect(try decoded.hostSpeakerOutcome.domainValue().clusters[1].disposition == .noMatch)
        var legacy = wire; legacy.clearHostSpeakerOutcome()
        #expect(try legacy.validatedHostSpeakerOutcome(canonicalID: canonical, originID: origin,
            canonicalPCMHash: outcome.canonicalPCMHash, producerDeviceID: outcome.producerDeviceID) == nil)
    }
    @Test func malformedOrContradictoryClaimsAreRejected() throws {
        let (outcome, origin) = try fixture()
        let original = status(outcome, origin: origin)
        let mutations: [(inout Harc_V1_ProcessingStatusV1) -> Void] = [
            { $0.clearCanonicalRecordingID() }, { $0.clearOriginRecordingID() },
            { $0.canonicalAudioSha256.value = Data(repeating: 8, count: 32) },
            { $0.processing = .init(.pending) }, { $0.projection = .init(.pending) },
            { $0.selectedEdgeBundleSha256.value = Data(repeating: 3, count: 32) },
            { $0.hostSpeakerOutcome.producerDeviceID.sha256 = Data(repeating: 8, count: 32) },
            { $0.hostSpeakerOutcome.canonicalRecordingID = .init(.random()) },
            { $0.hostSpeakerOutcome.canonicalAudioSha256.value = Data(repeating: 8, count: 32) },
            { $0.hostSpeakerOutcome.processingArtifactSha256.value = Data() },
            { $0.hostSpeakerOutcome.diarization = .UNRECOGNIZED(77) },
            { $0.hostSpeakerOutcome.diarization = .hostSpeakerDiarizationStateDisabled },
            { $0.hostSpeakerOutcome.clusters[0].clearSpeakerIndex() },
            { $0.hostSpeakerOutcome.clusters[0].state = .UNRECOGNIZED(77) },
            { $0.hostSpeakerOutcome.clusters[0].recognitionPackRevision = 1 },
            { $0.hostSpeakerOutcome.clusters[1].clearDecisionOperationID() },
            { $0.hostSpeakerOutcome.clusters[1].clearEvidenceSha256() },
            { $0.hostSpeakerOutcome.clusters[1].clearRecognitionPackRevision() },
            { $0.hostSpeakerOutcome.clusters[1].disposition = .UNRECOGNIZED(77) },
            { $0.hostSpeakerOutcome.clusters.append($0.hostSpeakerOutcome.clusters[0]) }
        ]
        for mutate in mutations {
            var wire = original; mutate(&wire)
            #expect(throws: (any Error).self) {
                try wire.validatedHostSpeakerOutcome(canonicalID: canonical, originID: origin,
                    canonicalPCMHash: outcome.canonicalPCMHash, producerDeviceID: outcome.producerDeviceID)
            }
        }
    }
}
