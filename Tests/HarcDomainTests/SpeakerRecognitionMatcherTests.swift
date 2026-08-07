import Foundation
import HarcDomain
import Testing

@Suite("Speaker recognition matcher")
struct SpeakerRecognitionMatcherTests {
    @Test("selects a confident host profile and rejects expired packs")
    func matchAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let personID = PersonID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let prototypeID = SpeakerPrototypeID(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let vector: [Float] = [1, 0, 0, 0]
        let prototype = try SpeakerRecognitionPrototype(
            id: prototypeID,
            embedding: .quantizing(vector),
            speechDurationMs: 5_000,
            segmentCount: 2
        )
        let profile = try SpeakerIdentityProfile(
            id: personID,
            displayName: "Frank Thomas",
            matchThreshold: 0.8,
            revision: .initial,
            prototypes: [prototype]
        )
        let pack = try SpeakerRecognitionPack(
            revision: try EntityRevision(7),
            modelID: "wespeaker_v2",
            dimensions: 4,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(60),
            profiles: [profile]
        )

        let match = SpeakerRecognitionMatcher.bestMatch(
            embedding: try .quantizing([0.99, 0.01, 0, 0]),
            modelID: "wespeaker_v2",
            pack: pack,
            at: now.addingTimeInterval(30)
        )
        #expect(match?.personID == personID)
        #expect(match?.displayName == "Frank Thomas")
        #expect(match?.packRevision == pack.revision)
        #expect(SpeakerRecognitionMatcher.bestMatch(
            embedding: try .quantizing(vector),
            modelID: "wespeaker_v2",
            pack: pack,
            at: pack.expiresAt
        ) == nil)
    }
}
