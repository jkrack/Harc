import Testing
@testable import HarcVoiceprint

@Suite("EmbedderKind")
struct EmbedderKindTests {
    @Test("wespeakerV2 has the canonical persisted string")
    func wespeakerV2Constant() {
        #expect(EmbedderKind.wespeakerV2 == "wespeaker_v2")
    }
}
