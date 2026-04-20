import Testing
import Foundation
@testable import HarcCore

@Suite("TranscribeRequest VAD field")
struct TranscribeRequestVADTests {
    @Test("default init sets vad = true")
    func defaultVADIsTrue() {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav")
        #expect(r.vad == true)
    }

    @Test("explicit init round-trips vad: false")
    func explicitVADFalse() {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)
        #expect(r.vad == false)
    }

    @Test("JSON decode without vad key defaults to true (fwd-compat)")
    func decodeWithoutVADKey() throws {
        let json = #"{"audioPath":"/tmp/x.wav","language":"en","wantTimestamps":true,"diarize":true}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(TranscribeRequest.self, from: json)
        #expect(r.vad == true)
    }

    @Test("JSON decode with vad:false honours the payload")
    func decodeWithVADFalse() throws {
        let json = #"{"audioPath":"/tmp/x.wav","vad":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(TranscribeRequest.self, from: json)
        #expect(r.vad == false)
    }

    @Test("JSON encode includes vad")
    func encodeIncludesVAD() throws {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"vad\":false"))
    }
}
