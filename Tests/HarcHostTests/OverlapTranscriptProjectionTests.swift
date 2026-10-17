import Testing
import Foundation
import HarcProtocol
import HarcProtocolWire
@testable import HarcHost

@Suite("Accepted overlap transcript projection")
struct OverlapTranscriptProjectionTests {
    @Test func speakerBearingArtifactsRequireHostProcessingUntilClusterAuthorityIsBound() {
        var transcript = Harc_V1_TranscriptArtifactV1()
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "retained words"
        transcript.utterances = [utterance]
        var diarization = Harc_V1_DiarizationArtifactV1()
        func accepts() -> Bool {
            HarcHostProcessingArtifactService.canProjectSpeakerInformation([
                .transcript(exactPayload: Data(), value: transcript),
                .diarization(exactPayload: Data(), value: diarization)])
        }
        #expect(accepts())
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 1; range.endFrameExclusive = 3
        transcript.overlapAssessment.ranges = [range]
        #expect(accepts()) // Raw overlap alone can be projected without identity claims.
        var turn = Harc_V1_SpeakerTurnV1()
        turn.startFrame = 0; turn.endFrameExclusive = 16; turn.localClusterID = "speaker-0"
        diarization.turns = [turn]
        #expect(!accepts())
        diarization.turns = []
        transcript.utterances[0].localSpeakerID = "speaker-0"
        #expect(!accepts())
        transcript.utterances[0].clearLocalSpeakerID()
        var word = Harc_V1_TranscriptWordV1()
        word.text = "retained"; word.localSpeakerID = "speaker-0"
        transcript.utterances[0].words = [word]
        #expect(!accepts())
    }

    @Test func onlyDetectedOverlapAddsWarningAndNeverDropsText() {
        var transcript = Harc_V1_TranscriptArtifactV1()
        var utterance = Harc_V1_TranscriptUtteranceV1()
        utterance.text = "retained words"
        transcript.utterances = [utterance]
        #expect(HarcHostProcessingArtifactService.acceptedTranscriptText(transcript) == "retained words")
        transcript.overlapAssessment = Harc_V1_SpeechOverlapAssessmentV1()
        #expect(HarcHostProcessingArtifactService.acceptedTranscriptText(transcript) == "retained words")
        var range = Harc_V1_CanonicalFrameRangeV1()
        range.startFrame = 1; range.endFrameExclusive = 3
        transcript.overlapAssessment.ranges = [range]
        #expect(HarcHostProcessingArtifactService.acceptedTranscriptText(transcript) ==
            "Overlapping voices detected. Speaker attribution may be incomplete.\n\nretained words")
    }
}
