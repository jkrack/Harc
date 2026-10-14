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
        var enabled: Int32 = 1
        for fd in pair {
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        return (pair[0], pair[1])
    }

    @Test("status() sends an IPC status request and decodes the response")
    func statusRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let expected = DaemonStatus(version: "0.1.0", modelLoaded: true, uptimeSeconds: 42)

        let fakeDaemon = SocketTestResponder(fd: serverFd) {
            let request: IPCRequest = try HarcSTTClientTests.readOnlyBlocking(fd: serverFd)
            #expect(request == .status)
            try HarcSTTClientTests.writeOnly(IPCResponse.status(expected), to: serverFd)
        }

        let client = HarcSTTClient(connectedFd: clientFd)
        let status = try await client.status()
        #expect(status == expected)
        try await fakeDaemon.wait()
    }

    /// Regression: the old racing-task-group "timeout" could never actually
    /// return early — a throwing task group awaits all children, and the
    /// round-trip child sat in an uncancellable blocking read(), so a silent
    /// daemon held the caller for as long as the daemon stayed silent. This
    /// test was impossible to write against that implementation: it would
    /// have hung. The kernel-level SO_RCVTIMEO deadline makes it pass.
    @Test("a silent daemon trips the timeout instead of blocking forever")
    func silentPeerTimesOut() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(serverFd); close(clientFd) }   // held open, never written to: a wedged daemon

        let client = HarcSTTClient(connectedFd: clientFd)
        await #expect {
            _ = try await client.roundTripWithTimeout(.status, seconds: 1)
        } throws: { error in
            if case ClientError.timeout(let seconds) = error { return seconds == 1 }
            return false
        }
        // Measure the actual I/O deadline inside its worker. Caller resumption
        // can be delayed by unrelated CPU work in a full single-worker suite.
        let measured = try await HarcBlockingIO.run { () -> (TimeInterval, ClientError?) in
            let began = Date()
            do {
                _ = try client.roundTripBlocking(.status, timeoutSeconds: 1)
                return (Date().timeIntervalSince(began), nil)
            } catch let error as ClientError {
                return (Date().timeIntervalSince(began), error)
            }
        }
        if case .timeout(let seconds)? = measured.1 {
            #expect(seconds == 1)
        } else {
            Issue.record("silent socket must fail with the exact kernel timeout")
        }
        #expect(measured.0 < 5)

    }

    @Test("transcribe() sends a transcribe request and decodes a result")
    func transcribeRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let result = TranscribeResult(
            text: "hello world",
            words: [Word(text: "hello", startMs: 0, endMs: 500)],
            speakers: [],
            processingMs: 42
        )

        let fakeTask = SocketTestResponder(fd: serverFd) { [serverFd] in
            let req: IPCRequest = try HarcSTTClientTests.readOnlyBlocking(fd: serverFd)
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
        try await fakeTask.wait()
    }

    @Test("transcribe() maps .error responses to ClientError.transcribeFailed")
    func transcribeErrorMapping() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let fakeTask = SocketTestResponder(fd: serverFd) { [serverFd] in
            _ = try HarcSTTClientTests.readOnlyBlocking(fd: serverFd) as IPCRequest
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
        try await fakeTask.wait()
    }

    @Test("termination shuts down a healthy daemon not spawned by this launcher")
    func shutdownInheritedDaemon() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let fakeDaemon = SocketTestResponder(fd: serverFd) { [serverFd] in
            let request: IPCRequest = try HarcSTTClientTests.readOnlyBlocking(fd: serverFd)
            #expect(request == .shutdown)
            try HarcSTTClientTests.writeOnly(
                IPCResponse.status(DaemonStatus(
                    version: "test",
                    modelLoaded: true,
                    uptimeSeconds: 1
                )),
                to: serverFd
            )
        }

        // This launcher owns no Process. The shutdown request must still reach
        // the inherited healthy daemon through its socket connection.
        let launcher = DaemonLauncher()
        await launcher.shutdownDaemon(client: HarcSTTClient(connectedFd: clientFd))
        try await fakeDaemon.wait()
    }

    // Helpers run on dedicated fixture threads.
    static func readOnlyBlocking<T: Decodable>(fd: Int32) throws -> T {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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

    @Test("diarize sends DiarizeRequest and returns DiarizeResult")
    func diarizeRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let expectedResult = DiarizeResult(
            segments: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1500)],
            speakers: [SpeakerEmbeddingRow(
                speakerIndex: 0,
                vector: [Float](repeating: 0.0625, count: 256),
                totalMs: 1500,
                segmentCount: 1
            )],
            processingMs: 42
        )

        let fakeTask = SocketTestResponder(fd: serverFd) { [serverFd] in
            let req: IPCRequest = try HarcSTTClientTests.readOnlyBlocking(fd: serverFd)
            if case .diarize(let dreq) = req {
                #expect(dreq.audioPath == "/tmp/dx.wav")
            } else {
                Issue.record("expected .diarize, got \(req)")
            }
            try HarcSTTClientTests.writeOnly(IPCResponse.diarization(expectedResult), to: serverFd)
        }

        let client = HarcSTTClient(connectedFd: clientFd)
        let result = try await client.diarize(audioPath: "/tmp/dx.wav")
        #expect(result.segments.count == 1)
        #expect(result.speakers.count == 1)
        #expect(result.speakers[0].vector.count == 256)
        #expect(result.processingMs == 42)
        try await fakeTask.wait()
    }
}

/// Start the peer immediately, before the client can block its executor thread,
/// and retain a completion stream so failures and lifetime stay within the test.
private struct SocketTestResponder: Sendable {
    private let completion: AsyncThrowingStream<Void, Error>

    init(fd: Int32, _ operation: @escaping @Sendable () throws -> Void) {
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        completion = stream
        Thread {
            defer { close(fd) }
            do {
                try operation()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }.start()
    }

    func wait() async throws {
        for try await _ in completion { }
    }
}
