import Foundation
import HarcDomain
import Testing

@Suite("Speaker recognition matcher")
struct SpeakerRecognitionMatcherTests {
    @Test("cached packs cannot enroll short voice evidence")
    func shortEnrollmentAbstains() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for duration: UInt64 in [4_999, 5_000] {
            let prototype = try SpeakerRecognitionPrototype(id: .random(),
                embedding: .quantizing([1, 0]), speechDurationMs: duration, segmentCount: 1)
            let profile = try SpeakerIdentityProfile(id: .random(), displayName: "Alice",
                matchThreshold: 0.65, revision: .initial, prototypes: [prototype])
            let pack = try SpeakerRecognitionPack(revision: .initial, modelID: "wespeaker_v2",
                dimensions: 2, generatedAt: now, expiresAt: now.addingTimeInterval(60), profiles: [profile])
            let match = SpeakerRecognitionMatcher.bestMatch(embedding: try .quantizing([1, 0]),
                modelID: "wespeaker_v2", pack: pack, at: now)
            #expect((match != nil) == (duration == 5_000))
        }
    }

    @Test("distinct people with tied or nearby scores remain unknown")
    func ambiguousPeople() {
        let a = PersonID.random(), b = PersonID.random()
        for scores in [[a: 0.9, b: 0.9], [a: 0.9, b: 0.88], [b: 0.9, a: 0.88]] {
            #expect(SpeakerRecognitionMatcher.unambiguousBestPerson(scores: scores) == nil)
        }
        #expect(SpeakerRecognitionMatcher.unambiguousBestPerson(scores: [a: 0.9, b: 0.7]) == a)
        #expect(SpeakerRecognitionMatcher.unambiguousBestPerson(scores: [a: .nan]) == nil)
        #expect(SpeakerRecognitionMatcher.unambiguousBestPerson(scores: [a: 0]) == nil)
    }

    @Test("multiple prototypes belong to one identity; nearby competing identities cause abstention")
    func pooledProfiles() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let a = PersonID.random(), b = PersonID.random()
        func profile(_ id: PersonID, _ vectors: [[Float]]) throws -> SpeakerIdentityProfile {
            let prototypes = try vectors.map { vector in
                try SpeakerRecognitionPrototype(id: .random(), embedding: .quantizing(vector),
                                                speechDurationMs: 5_000, segmentCount: 2)
            }.sorted { $0.id < $1.id }
            return try SpeakerIdentityProfile(id: id, displayName: id == a ? "Alice" : "Bob",
                                              matchThreshold: 0.65, revision: .initial, prototypes: prototypes)
        }
        func match(_ profiles: [SpeakerIdentityProfile]) throws -> ProvisionalSpeakerMatch? {
            let pack = try SpeakerRecognitionPack(revision: .initial, modelID: "wespeaker_v2",
                dimensions: 4, generatedAt: now, expiresAt: now.addingTimeInterval(60),
                profiles: profiles.sorted { $0.id < $1.id })
            return SpeakerRecognitionMatcher.bestMatch(embedding: try .quantizing([1,0,0,0]),
                                                       modelID: "wespeaker_v2", pack: pack, at: now)
        }
        let alice = try profile(a, [[1,0,0,0], [0.99,0.01,0,0]])
        #expect(try match([alice])?.personID == a)
        #expect(try match([alice, profile(b, [[0.99,0.01,0,0]])]) == nil)
        #expect(try match([alice, profile(b, [[0,1,0,0]])])?.personID == a)
    }

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
