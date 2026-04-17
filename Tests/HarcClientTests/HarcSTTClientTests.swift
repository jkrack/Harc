import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcClient

@Suite("HarcSTTClient")
struct HarcSTTClientTests {
    /// Makes a connected pair of AF_UNIX fds so we can play fake-daemon in-process.
    private func makePair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        let ok = pair.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try #require(ok == 0, "socketpair failed")
        return (pair[0], pair[1])
    }

    @Test("status() sends an IPC status request and decodes the response")
    func statusRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(serverFd) }

        let expected = DaemonStatus(version: "0.1.0", modelLoaded: true, uptimeSeconds: 42)

        let fakeTask = Task.detached { [serverFd] in
            let req: IPCRequest = try await HarcSTTClientTests.readOnly(fd: serverFd)
            #expect(req == .status)
            try HarcSTTClientTests.writeOnly(IPCResponse.status(expected), to: serverFd)
        }

        let client = HarcSTTClient(connectedFd: clientFd)
        let status = try await client.status()
        #expect(status == expected)
        try await fakeTask.value
    }

    @Test("transcribe() sends a transcribe request and decodes a result")
    func transcribeRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(serverFd) }

        let result = TranscribeResult(
            text: "hello world",
            words: [Word(text: "hello", startMs: 0, endMs: 500)],
            speakers: [],
            processingMs: 42
        )

        let fakeTask = Task.detached { [serverFd] in
            let req: IPCRequest = try await HarcSTTClientTests.readOnly(fd: serverFd)
            if case .transcribe(let r) = req {
                #expect(r.audioPath == "/tmp/x.wav")
                #expect(r.diarize == false)
            } else {
                Issue.record("expected transcribe request")
            }
            try HarcSTTClientTests.writeOnly(IPCResponse.result(result), to: serverFd)
        }

        let client = HarcSTTClient(connectedFd: clientFd)
        let out = try await client.transcribe(audioPath: "/tmp/x.wav", diarize: false)
        #expect(out == result)
        try await fakeTask.value
    }

    @Test("transcribe() maps .error responses to ClientError.transcribeFailed")
    func transcribeErrorMapping() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(serverFd) }

        let fakeTask = Task.detached { [serverFd] in
            _ = try await HarcSTTClientTests.readOnly(fd: serverFd) as IPCRequest
            try HarcSTTClientTests.writeOnly(
                IPCResponse.error(IPCError(code: "audio_load_failed", message: "no such file")),
                to: serverFd
            )
        }

        let client = HarcSTTClient(connectedFd: clientFd)
        await #expect {
            _ = try await client.transcribe(audioPath: "/nope.wav", diarize: false)
        } throws: { error in
            if case ClientError.transcribeFailed(let code, _) = error { return code == "audio_load_failed" }
            return false
        }
        try await fakeTask.value
    }

    // Helpers reachable from the detached fake tasks.
    static func readOnly<T: Decodable>(fd: Int32) async throws -> T {
        var buf = Data()
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { scratch.deallocate() }
        while !buf.contains(0x0A) {
            let n = read(fd, scratch, 4096)
            if n > 0 { buf.append(scratch, count: n) } else { break }
        }
        let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
        return try JSONDecoder().decode(T.self, from: buf.prefix(upTo: nl))
    }

    static func writeOnly<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }
}
