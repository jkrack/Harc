import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("FTS search")
struct FTSSearchTests {
    private func sample(wav: String, transcript: String?, title: String? = nil) -> Recording {
        Recording(
            wavPath: wav,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: title,
            transcriptText: transcript
        )
    }

    @Test("search returns only transcript-body matches — title-only matches are filtered out")
    func onlyTranscriptBody() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "hello world", title: "Unrelated"))
        _ = try await store.upsert(sample(wav: "/tmp/b.wav", transcript: "completely different", title: "hello"))
        let hits = try await store.search(query: "hello")
        #expect(hits.map { $0.recording.wavPath } == ["/tmp/a.wav"])
    }

    @Test("search ranks rarer term hits above common-term noise (BM25)")
    func bm25Ranking() async throws {
        let store = try await RecordingStore.inMemory()
        let long = String(repeating: "the quick brown fox jumped over the lazy dog ", count: 50) + " budget"
        _ = try await store.upsert(sample(wav: "/tmp/long.wav", transcript: long))
        _ = try await store.upsert(sample(wav: "/tmp/short.wav", transcript: "the annual budget meeting"))
        let hits = try await store.search(query: "budget")
        #expect(hits.count == 2)
        #expect(hits[0].recording.wavPath == "/tmp/short.wav")
    }

    @Test("Porter stemmer matches across English inflections")
    func porterStem() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "we are renewing the contract"))
        let hits = try await store.search(query: "renewals")
        #expect(hits.count == 1)
    }

    @Test("search excludes soft-deleted recordings")
    func excludesDeleted() async throws {
        let store = try await RecordingStore.inMemory()
        let r = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "budget"))
        try await store.softDelete(id: r.id!)
        let hits = try await store.search(query: "budget")
        #expect(hits.isEmpty)
    }

    @Test("whitespace-only query returns empty")
    func emptyQuery() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "hello"))
        #expect(try await store.search(query: "   ").isEmpty)
        #expect(try await store.search(query: "").isEmpty)
    }

    @Test("FTS5 operator characters in user input do not raise")
    func sanitisesOperators() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "the annual budget"))
        _ = try await store.search(query: "\"budget\"")
        _ = try await store.search(query: "budget AND meeting")
        _ = try await store.search(query: "budget NOT meeting")
        _ = try await store.search(query: "(budget)")
        _ = try await store.search(query: "field:budget")
    }

    @Test("snippet wraps matched term in <mark> sentinels")
    func snippetMarks() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(sample(wav: "/tmp/a.wav", transcript: "quarterly planning for the budget review"))
        let hits = try await store.search(query: "budget")
        let hit = try #require(hits.first)
        #expect(hit.snippet.contains("<mark>"))
        #expect(hit.snippet.contains("</mark>"))
    }

    @Test("search results are capped at 200")
    func resultsCapped() async throws {
        let store = try await RecordingStore.inMemory()
        for i in 0..<250 {
            _ = try await store.upsert(sample(wav: "/tmp/\(i).wav", transcript: "budget line item \(i)"))
        }
        let hits = try await store.search(query: "budget")
        #expect(hits.count == 200)
    }
}
