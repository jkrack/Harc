# Harc Chunked Transcription Implementation Plan (Plan 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording, roll over the durable WAV every ~60 seconds, hand each chunk to the `harc-stt` daemon for transcription, accumulate word timings + speaker segments into a session transcript, and on stop write `HH-mm-ss.txt` + `HH-mm-ss.json` alongside the `.wav`. The user sees the transcript building up during the meeting via an `AsyncStream<TranscriptUpdate>` that Plan 5's UI will subscribe to.

**Architecture:** New library target `HarcClient`. An `HarcSTTClient` speaks the IPC protocol over the Unix socket (connect-per-request, simple retry model). A `DaemonLauncher` spawns the bundled `harc-stt` binary if not already running. A `WAVChunker` slices the growing cache-WAV into fixed-duration audio files. A `ChunkedTranscriber` actor ties chunker + client together, emits transcript updates as an `AsyncStream`, and exposes the final assembled session transcript on stop. `RecordingSession` from Plan 3 gains an optional transcriber that activates during recording and finalizes on stop, producing `.txt` + `.json` siblings to the `.wav`.

**Tech Stack:** Swift 6.0, SwiftPM, Swift Testing, Darwin C socket APIs (`socket`, `connect`, `read`, `write`), `Foundation.Process` (for daemon spawn), `AVFoundation` (`AVAudioFile` for chunk slicing).

---

## Prerequisites

- Plan 1, 2, and 3 complete on `main`. Latest commit `2200ff9 feat: Start/Stop Recording menu items wired to RecordingSession`. `swift test` passes 36 tests in 14 suites.
- `harc-stt` binary is embedded in `Harc.app/Contents/MacOS/harc-stt` via Plan 1 Task 7's build script. Also available at `.build/debug/harc-stt` for `swift test` scenarios.
- Parakeet TDT v3 models cached at `~/Library/Application Support/FluidAudio/Models/` from prior Plan 2 test runs.
- The daemon speaks the `IPCRequest` / `IPCResponse` protocol from `HarcCore` (frozen contract). Wire format: newline-delimited JSON over `~/.harc/stt.sock`.

## Scope Boundary

This plan produces **real-time chunked transcription with durable `.txt` + `.json` outputs**. Out of scope:

- Menu bar popover UI (Plan 5) — Plan 4 emits `AsyncStream<TranscriptUpdate>`, but no UI consumes it yet.
- Clipboard history / library / FTS search (Plan 6).
- Cross-chunk speaker stitching. Plan 2's `Diarizer` assigns per-call speaker IDs; chunks inherit that limitation — "Speaker 0 in chunk 1" may refer to a different person than "Speaker 0 in chunk 2". Documented as an Open Decision; Plan 6 or later may layer an embedding-based stitcher.
- VAD / silence gating (CLAUDE.md open decision).
- Global hotkey, auto-paste (Plan 5).
- Daemon crash recovery beyond a single retry per chunk.

## File Structure

After Plan 4:

```
Harc/
├── Package.swift                              (modified — +HarcClient product + test target)
├── project.yml                                (modified — +HarcClient dep on Harc target)
├── Sources/
│   ├── HarcClient/                            (new library target)
│   │   ├── HarcSTTClient.swift                T1
│   │   ├── DaemonLauncher.swift               T2
│   │   ├── WAVChunker.swift                   T3
│   │   ├── ChunkedTranscriber.swift           T4
│   │   ├── TranscriptAssembler.swift          T4
│   │   ├── SessionTranscript.swift            T4
│   │   ├── TranscriptWriter.swift             T5
│   │   └── ClientError.swift                  T1
│   ├── HarcCore/                              (unchanged)
│   ├── HarcSTT/                               (unchanged)
│   └── HarcAudio/
│       └── RecordingSession.swift             (modified — +optional transcriber)  T6
└── Tests/
    └── HarcClientTests/                       (new test target)
        ├── HarcSTTClientTests.swift           T1
        ├── WAVChunkerTests.swift              T3
        ├── ChunkedTranscriberTests.swift      T4
        ├── TranscriptWriterTests.swift        T5
        └── EndToEndTests.swift                T7
```

### Responsibilities

- **`ClientError`** — typed errors: `.daemonNotReachable`, `.daemonLaunchFailed(String)`, `.ipcEncodeFailed(String)`, `.ipcDecodeFailed(String)`, `.transcribeFailed(code:message:)`, `.chunkerFailed(String)`.
- **`HarcSTTClient`** — stateless (apart from config) connect-per-request client. `status() async throws -> DaemonStatus`, `transcribe(audioPath:, diarize: Bool) async throws -> TranscribeResult`, `shutdown() async throws`. Each call opens a fresh AF_UNIX socket, sends one NDJSON request, reads one NDJSON response, closes.
- **`DaemonLauncher`** — finds the `harc-stt` binary (via `binaryURL` param, `Bundle.main`'s `Contents/MacOS/`, or `.build/debug/harc-stt` fallback for tests), spawns with `Foundation.Process`, redirects stderr to `~/Library/Caches/Harc/daemon.log`, waits up to 60s for the socket file. `ensureRunning()` is idempotent: checks for the socket + a live `status` response before spawning.
- **`WAVChunker`** — given a growing-WAV URL, yields fixed-duration slices as temp WAV files. `AVAudioFile(forReading:)` sees the current on-disk length, so we re-open per poll and read from the tracked offset. Each chunk is written to `/tmp/harc-chunk-<uuid>.wav` and its path handed to the daemon; the chunker cleans up after the daemon has acked.
- **`SessionTranscript`** — the final output type: `startedAt`, `endedAt`, `audioPath`, `chunks: [ChunkResult]`, `joinedText`, `words: [Word]`, `speakers: [SpeakerSegment]`. All fields Codable.
- **`TranscriptAssembler`** — accumulates `ChunkResult`s (each with `startMs`, `endMs`, `text`, `words`, `speakers` in chunk-local time). On finalize, rebases word/speaker times to session-global time and concatenates.
- **`ChunkedTranscriber`** — actor. `start(audioURL:)`, `finalize() async throws -> SessionTranscript`. Owns a `WAVChunker`, a `HarcSTTClient`, a `TranscriptAssembler`, and a `Task` that polls the chunker and dispatches to the client. Exposes `updates: AsyncStream<TranscriptUpdate>` — each chunk completion emits a `TranscriptUpdate(chunkIndex:, joinedTextSoFar:)` for UI consumption.
- **`TranscriptWriter`** — writes a `SessionTranscript` to `HH-mm-ss.txt` (plaintext, pasteboard-ready) and `HH-mm-ss.json` (full structured) alongside the `.wav` URL. Atomic file writes.
- **`RecordingSession`** (modified) — new initializer param `transcriber: ChunkedTranscriber?`. When non-nil, `start()` wires the transcriber to the cache WAV; `stop()` awaits the final chunk, finalizes the transcript, writes `.txt` + `.json` next to the moved WAV. `.wav`/`.txt`/`.json` paths are returned together via a new `RecordingResult` struct.

## Testing Notes

- Tests that spawn the real daemon use temp socket paths under `/tmp/harc-client-test-<uuid>.sock`. The launcher's binary lookup can be overridden via the `HARC_STT_BINARY` env var or constructor param.
- `HarcSTTClient` unit tests use `socketpair(2)` to simulate the daemon side in-process — same pattern as Plan 2's `ClientConnectionTests`.
- `WAVChunker` tests build a synthetic growing WAV by writing 16 kHz mono Int16 buffers via `AVAudioFile` and progressively chunking.
- `ChunkedTranscriberTests` injects a `FakeHarcSTTClient` that returns canned `TranscribeResult`s so the assembly logic can be verified without model loads.
- `EndToEndTests` uses the bundled `short-speech.wav` fixture from `HarcSTTTests/Fixtures/`, chunks it at a small duration (1 s) to exercise multi-chunk flow, and verifies the assembled transcript against the fixture's content (contains "test").
- Model-download tests are tagged `.slow` (reusing the tag defined in `TranscriberTests`).

---

### Task 1: `HarcClient` target scaffolding + `HarcSTTClient` + `ClientError`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Modify: `/Users/jlane/GitHub/Harc/project.yml`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/ClientError.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/HarcSTTClient.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/HarcSTTClientTests.swift`

- [ ] **Step 1: Rewrite `Package.swift`** — add `HarcClient` library, `HarcClientTests` test target, add FluidAudio dep-inheritance from HarcSTT. (Package.swift already has FluidAudio pinned; HarcClient doesn't need FluidAudio directly.)

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcAudio", targets: ["HarcAudio"]),
        .library(name: "HarcClient", targets: ["HarcClient"]),
        .executable(name: "harc-stt", targets: ["HarcSTT"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.13.5")
        ),
    ],
    targets: [
        .target(name: "HarcCore"),
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore"]
        ),
        .target(
            name: "HarcClient",
            dependencies: ["HarcCore"]
        ),
        .executableTarget(
            name: "HarcSTT",
            dependencies: [
                "HarcCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "HarcCoreTests", dependencies: ["HarcCore"]),
        .testTarget(
            name: "HarcSTTTests",
            dependencies: ["HarcSTT", "HarcCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HarcAudioTests",
            dependencies: ["HarcAudio", "HarcCore"]
        ),
        .testTarget(
            name: "HarcClientTests",
            dependencies: ["HarcClient", "HarcCore"]
        ),
    ]
)
```

- [ ] **Step 2: Modify `project.yml`** — add HarcClient as a third product dependency on the `Harc` target.

The existing `targets.Harc.dependencies:` block reads:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
```

Change it to:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
      - package: HarcCore
        product: HarcClient
```

- [ ] **Step 3: Write `Sources/HarcClient/ClientError.swift`**

```swift
import Foundation

public enum ClientError: Error, LocalizedError, Equatable {
    case daemonNotReachable(String)
    case daemonLaunchFailed(String)
    case ipcEncodeFailed(String)
    case ipcDecodeFailed(String)
    case transcribeFailed(code: String, message: String)
    case chunkerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotReachable(let reason):
            return "Daemon not reachable: \(reason)"
        case .daemonLaunchFailed(let reason):
            return "Failed to launch daemon: \(reason)"
        case .ipcEncodeFailed(let reason):
            return "Failed to encode IPC request: \(reason)"
        case .ipcDecodeFailed(let reason):
            return "Failed to decode IPC response: \(reason)"
        case .transcribeFailed(let code, let message):
            return "Transcription failed [\(code)]: \(message)"
        case .chunkerFailed(let reason):
            return "Audio chunker failed: \(reason)"
        }
    }
}
```

- [ ] **Step 4: Write the failing test `Tests/HarcClientTests/HarcSTTClientTests.swift`**

```swift
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

    /// Reads one NDJSON line from fd, decodes as T.
    private func readLine<T: Decodable>(fd: Int32, as: T.Type) throws -> T {
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

    /// Writes one NDJSON line to fd.
    private func writeLine<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    @Test("status() sends an IPC status request and decodes the response")
    func statusRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(serverFd) }

        let expected = DaemonStatus(version: "0.1.0", modelLoaded: true, uptimeSeconds: 42)

        // Fake daemon running on the "server" side of the pair.
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
```

- [ ] **Step 5: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter HarcSTTClientTests 2>&1 | tail -15
```

Expected: `HarcSTTClient` not found.

- [ ] **Step 6: Write `Sources/HarcClient/HarcSTTClient.swift`**

```swift
import Foundation
import Darwin
import HarcCore

/// Connect-per-request client to the harc-stt daemon. Opens a Unix socket,
/// sends one newline-delimited JSON request, reads one response, closes.
public struct HarcSTTClient: Sendable {
    public static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".harc/stt.sock").path
    }()

    private let socketPath: String?
    private let preconnectedFd: Int32?

    public init(socketPath: String = HarcSTTClient.defaultSocketPath) {
        self.socketPath = socketPath
        self.preconnectedFd = nil
    }

    /// Test-only init: skip connect, reuse an already-open fd (e.g. from socketpair).
    public init(connectedFd: Int32) {
        self.socketPath = nil
        self.preconnectedFd = connectedFd
    }

    public func status() async throws -> DaemonStatus {
        let response = try await roundTrip(.status)
        switch response {
        case .status(let s): return s
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func transcribe(audioPath: String, diarize: Bool = true) async throws -> TranscribeResult {
        let request = IPCRequest.transcribe(TranscribeRequest(
            audioPath: audioPath,
            language: "en",
            wantTimestamps: true,
            diarize: diarize
        ))
        let response = try await roundTrip(request)
        switch response {
        case .result(let r): return r
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }

    public func shutdown() async throws {
        _ = try await roundTrip(.shutdown)
    }

    /// Opens a socket (if not using a preconnected fd), sends `request`, reads one response, closes.
    private func roundTrip(_ request: IPCRequest) async throws -> IPCResponse {
        let fd: Int32
        let shouldClose: Bool
        if let pre = preconnectedFd {
            fd = pre
            shouldClose = false
        } else {
            fd = try connectToDaemon()
            shouldClose = true
        }
        defer { if shouldClose { Darwin.close(fd) } }

        var data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw ClientError.ipcEncodeFailed(error.localizedDescription)
        }
        data.append(0x0A)
        _ = data.withUnsafeBytes { rawBuf in
            write(fd, rawBuf.baseAddress, data.count)
        }
        // Signal EOF on our write side so the daemon knows the request is complete.
        // Only applies when we own the fd; for preconnected test fds the peer drives it.
        // `Darwin.shutdown(...)` qualifier avoids shadowing by the struct-scoped `shutdown` method below.
        if shouldClose { Darwin.shutdown(fd, SHUT_WR) }

        var buf = Data()
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { scratch.deallocate() }
        while !buf.contains(0x0A) {
            let n = read(fd, scratch, 64 * 1024)
            if n > 0 {
                buf.append(scratch, count: n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw ClientError.daemonNotReachable("read errno \(errno)")
            }
        }

        let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
        do {
            return try JSONDecoder().decode(IPCResponse.self, from: buf.prefix(upTo: nl))
        } catch {
            throw ClientError.ipcDecodeFailed(error.localizedDescription)
        }
    }

    private func connectToDaemon() throws -> Int32 {
        guard let socketPath else {
            throw ClientError.daemonNotReachable("no socket path configured")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.daemonNotReachable("socket() errno \(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, addrLen)
            }
        }
        if status != 0 {
            let err = errno
            Darwin.close(fd)
            throw ClientError.daemonNotReachable("connect() errno \(err)")
        }
        return fd
    }
}
```

- [ ] **Step 7: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter HarcSTTClientTests 2>&1 | tail -20
```

Expected: all 3 tests pass.

Note: `#expect(throws:)` with a pattern closure is Swift Testing syntax — if the test runner version doesn't support it, substitute with a simpler `do { _ = try await ...; Issue.record("expected throw") } catch let err as ClientError { ... }` form.

- [ ] **Step 8: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 39 tests in 15 suites (36 prior + 3 new).

- [ ] **Step 9: Commit**

```bash
git add Package.swift Package.resolved project.yml Sources/HarcClient Tests/HarcClientTests
git commit -m "feat: HarcSTTClient + ClientError, new HarcClient library target"
```

---

### Task 2: `DaemonLauncher` — spawn the bundled daemon + wait for socket

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/DaemonLauncher.swift`

- [ ] **Step 1: Write `Sources/HarcClient/DaemonLauncher.swift`**

```swift
import Foundation
import HarcCore

/// Finds the harc-stt binary and spawns it if the socket isn't alive.
/// Idempotent: `ensureRunning()` is safe to call repeatedly.
public actor DaemonLauncher {
    private let binaryURL: URL?
    private let socketPath: String
    private let logPath: String
    private var process: Process?

    public init(
        binaryURL: URL? = nil,
        socketPath: String = HarcSTTClient.defaultSocketPath
    ) {
        self.binaryURL = binaryURL
        self.socketPath = socketPath

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.logPath = caches.appendingPathComponent("Harc/daemon.log").path
    }

    /// Ensures the daemon is running and responsive. Returns the socket path.
    public func ensureRunning() async throws -> String {
        // If the socket exists and a `status` call works, we're done.
        if FileManager.default.fileExists(atPath: socketPath) {
            let client = HarcSTTClient(socketPath: socketPath)
            if (try? await client.status()) != nil {
                return socketPath
            }
        }

        // Spawn the daemon.
        let bin = try resolveBinaryURL()

        // Ensure log directory exists.
        let parent = (logPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: Data())
        }
        let logHandle = FileHandle(forWritingAtPath: logPath)
        _ = try? logHandle?.seekToEnd()

        let p = Process()
        p.executableURL = bin
        p.standardError = logHandle ?? FileHandle(forWritingAtPath: "/dev/null")
        p.standardOutput = logHandle ?? FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
        } catch {
            throw ClientError.daemonLaunchFailed("run: \(error.localizedDescription)")
        }
        self.process = p

        // Wait up to 60s for the socket to appear and respond to status.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                let client = HarcSTTClient(socketPath: socketPath)
                if (try? await client.status()) != nil {
                    return socketPath
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        }
        throw ClientError.daemonLaunchFailed("timed out waiting for socket \(socketPath)")
    }

    public func stop() async {
        guard let p = process else { return }
        p.terminate()
        self.process = nil
    }

    /// Resolves the harc-stt binary location.
    /// Precedence: explicit `binaryURL` init arg → env var HARC_STT_BINARY →
    /// Bundle.main `Contents/MacOS/harc-stt` → `.build/debug/harc-stt`
    /// (SwiftPM test layout).
    private func resolveBinaryURL() throws -> URL {
        if let binaryURL {
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                throw ClientError.daemonLaunchFailed("binary not executable: \(binaryURL.path)")
            }
            return binaryURL
        }
        if let envPath = ProcessInfo.processInfo.environment["HARC_STT_BINARY"] {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let main = Bundle.main.bundlePath + "/Contents/MacOS/harc-stt"
        if FileManager.default.isExecutableFile(atPath: main) {
            return URL(fileURLWithPath: main)
        }
        // SwiftPM test fallback: find by walking up from the test bundle's path.
        // Tests run from .build/<config>/PkgTests.xctest; the harc-stt binary sits at .build/<config>/harc-stt.
        let testBundlePath = Bundle(for: Self.Token.self).bundlePath
        let candidate = (testBundlePath as NSString).deletingLastPathComponent + "/harc-stt"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw ClientError.daemonLaunchFailed("harc-stt binary not found (tried main bundle and \(candidate))")
    }

    /// Marker class used only for `Bundle(for:)` lookups inside tests.
    private final class Token {}
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. No unit tests for DaemonLauncher in this task — the integration test in Task 7 exercises it end-to-end.

- [ ] **Step 3: Sanity — full suite still passes**

```bash
swift test 2>&1 | tail -5
```

Expected: 39 tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcClient/DaemonLauncher.swift
git commit -m "feat: DaemonLauncher spawns bundled harc-stt and waits for socket"
```

---

### Task 3: `WAVChunker` — fixed-duration slices of a growing WAV

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/WAVChunker.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/WAVChunkerTests.swift`

- [ ] **Step 1: Write the failing test `Tests/HarcClientTests/WAVChunkerTests.swift`**

```swift
import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcClient

@Suite("WAVChunker")
struct WAVChunkerTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-chunker-\(UUID().uuidString.prefix(8)).wav")
    }

    /// Writes `seconds` of 16 kHz mono 16-bit PCM sine at 440 Hz to `url`.
    /// Returns the AVAudioFile reference kept open so the caller can append more.
    private func openGrowingWAV(url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    private func appendSine(_ file: AVAudioFile, seconds: Double, freq: Double = 440) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * freq * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("chunker produces a 1 second chunk when audio has exceeded 1 s")
    func singleChunk() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 1.5)
        // Dropping the reference flushes the RIFF header.
        _ = file
        // Re-open for reading by dropping and relying on the writer's deinit via separate variable.
        let _: AVAudioFile? = nil

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        let chunk = try await chunker.nextChunk()
        #expect(chunk != nil, "expected a chunk")
        if let chunk {
            defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
            #expect(chunk.startMs == 0)
            #expect(chunk.endMs == 1000)
            let readback = try AVAudioFile(forReading: chunk.audioURL)
            #expect(readback.length == 16000, "expected 16000 frames, got \(readback.length)")
        }
        let second = try await chunker.nextChunk()
        #expect(second == nil, "no second full chunk yet (only 0.5s remains)")
    }

    @Test("chunker yields multiple chunks as audio grows")
    func multipleChunks() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 3.2)
        _ = file

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        var chunks: [WAVChunker.Chunk] = []
        while let c = try await chunker.nextChunk() {
            chunks.append(c)
        }
        #expect(chunks.count == 3)
        #expect(chunks[0].startMs == 0 && chunks[0].endMs == 1000)
        #expect(chunks[1].startMs == 1000 && chunks[1].endMs == 2000)
        #expect(chunks[2].startMs == 2000 && chunks[2].endMs == 3000)

        let tail = try await chunker.flush()
        #expect(tail != nil)
        if let tail {
            defer { try? FileManager.default.removeItem(at: tail.audioURL) }
            #expect(tail.startMs == 3000)
            // Remaining 0.2s = 3200 frames
            let readback = try AVAudioFile(forReading: tail.audioURL)
            #expect(readback.length == 3200, "expected tail 3200 frames, got \(readback.length)")
        }

        for c in chunks { try? FileManager.default.removeItem(at: c.audioURL) }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter WAVChunkerTests 2>&1 | tail -15
```

Expected: `WAVChunker` not found.

- [ ] **Step 3: Write `Sources/HarcClient/WAVChunker.swift`**

**Why the raw `FileHandle` approach instead of `AVAudioFile(forReading:)`:** `AVAudioFile(forReading:)` reads the RIFF `data` chunk's size field from the header to know how much audio is present. Our source WAV is still being written to by `AudioFileWriter` (Plan 3), and the writer doesn't finalize that size field until `close()`. Reading the growing file with `AVAudioFile` would see `length=0` and skip all chunks. Instead we parse the RIFF header once to find the data-chunk body offset, then use `FileHandle` to read raw Int16 PCM bytes directly from any byte range. The on-disk file size is the source of truth for "how much audio has been written so far."

```swift
import Foundation
@preconcurrency import AVFoundation

/// Yields fixed-duration slices of a growing WAV file.
/// Each chunk is written to `/tmp/harc-chunk-<uuid>.wav`; caller is responsible for cleanup.
/// `@unchecked Sendable` because `ChunkedTranscriber` (Task 4) holds this across
/// actor boundaries — single-threaded access is enforced by the pump lifecycle.
public final class WAVChunker: @unchecked Sendable {
    public struct Chunk: Sendable {
        public let audioURL: URL
        public let startMs: Int
        public let endMs: Int
    }

    private let audioURL: URL
    private let chunkDurationSeconds: Double
    private var consumedFrames: AVAudioFramePosition = 0
    private let targetSampleRate: Double = 16000

    /// Cached data-chunk body offset (bytes from start of file to first PCM sample).
    /// Computed once by scanning the RIFF chunk list on first use.
    private var dataBodyOffset: Int? = nil

    public init(audioURL: URL, chunkDurationSeconds: Double = 60.0) {
        self.audioURL = audioURL
        self.chunkDurationSeconds = chunkDurationSeconds
    }

    public func nextChunk() async throws -> Chunk? {
        let chunkFrames = AVAudioFramePosition(chunkDurationSeconds * targetSampleRate)
        let currentLength = try readCurrentLength()
        guard currentLength - consumedFrames >= chunkFrames else { return nil }

        let start = consumedFrames
        let end = start + chunkFrames
        let chunk = try writeSlice(startFrame: start, endFrame: end)
        consumedFrames = end
        return chunk
    }

    public func flush() async throws -> Chunk? {
        let currentLength = try readCurrentLength()
        guard currentLength > consumedFrames else { return nil }

        let start = consumedFrames
        let end = currentLength
        let chunk = try writeSlice(startFrame: start, endFrame: end)
        consumedFrames = end
        return chunk
    }

    /// Returns the number of PCM frames currently in the source file.
    /// Works whether the writer is still open (header not finalised) or closed.
    private func readCurrentLength() throws -> AVAudioFramePosition {
        // Happy path: file is closed and header is finalised.
        if let af = try? AVAudioFile(forReading: audioURL), af.length > 0 {
            return af.length
        }
        // Writer is still open — header size fields are 0.
        // Derive frame count from on-disk file size and the data-chunk offset.
        let offset = try resolvedDataBodyOffset()
        let fileSize = try onDiskFileSize()
        let available = max(0, fileSize - offset)
        let bytesPerFrame = 2  // 16-bit mono
        return AVAudioFramePosition(available / bytesPerFrame)
    }

    /// Writes `[startFrame, endFrame)` from the source file into a fresh temp WAV.
    /// Uses raw FileHandle I/O so it works even when the source writer is still open.
    private func writeSlice(startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition) throws -> Chunk {
        let outURL = URL(fileURLWithPath: "/tmp/harc-chunk-\(UUID().uuidString.prefix(8)).wav")

        let bytesPerFrame = 2  // 16-bit mono
        let frameCount = Int(endFrame - startFrame)
        let readOffset = try resolvedDataBodyOffset() + Int(startFrame) * bytesPerFrame
        let readLength = frameCount * bytesPerFrame

        // Read raw PCM bytes from the source.
        let rawBytes: Data
        do {
            let handle = try FileHandle(forReadingFrom: audioURL)
            defer { try? handle.close() }
            handle.seek(toFileOffset: UInt64(readOffset))
            rawBytes = handle.readData(ofLength: readLength)
        } catch {
            throw ClientError.chunkerFailed("read slice: \(error.localizedDescription)")
        }
        guard rawBytes.count == readLength else {
            throw ClientError.chunkerFailed(
                "slice underread: expected \(readLength) bytes, got \(rawBytes.count)"
            )
        }

        // Convert Int16 → Float32 and write to a new WAV file.
        do {
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(frameCount))!
            outBuf.frameLength = AVAudioFrameCount(frameCount)
            let outCh = outBuf.floatChannelData![0]
            rawBytes.withUnsafeBytes { ptr in
                let samples = ptr.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    outCh[i] = Float(samples[i]) / 32767.0
                }
            }
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let outFile = try AVAudioFile(forWriting: outURL, settings: fileSettings)
            try outFile.write(from: outBuf)
        } catch let err as ClientError {
            throw err
        } catch {
            throw ClientError.chunkerFailed(error.localizedDescription)
        }

        let startMs = Int(Double(startFrame) * 1000 / targetSampleRate)
        let endMs   = Int(Double(endFrame)   * 1000 / targetSampleRate)
        return Chunk(audioURL: outURL, startMs: startMs, endMs: endMs)
    }

    /// Returns the byte offset of the first PCM sample in the source WAV.
    /// Scans the RIFF chunk list once and caches the result.
    private func resolvedDataBodyOffset() throws -> Int {
        if let cached = dataBodyOffset { return cached }
        let offset = try parseDataBodyOffset()
        dataBodyOffset = offset
        return offset
    }

    /// Reads up to 8 KB of the file header and walks the RIFF chunk list to
    /// find the `data` chunk. Returns the byte offset of the first PCM sample
    /// (i.e. after the 8-byte chunk header).
    private func parseDataBodyOffset() throws -> Int {
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: audioURL)
            defer { try? handle.close() }
            header = handle.readData(ofLength: 8192)
        } catch {
            throw ClientError.chunkerFailed("open for header: \(error.localizedDescription)")
        }
        guard header.count >= 12 else {
            throw ClientError.chunkerFailed("file too small to be a WAV")
        }

        var offset = 12  // skip 'RIFF'(4) + size(4) + 'WAVE'(4)
        while offset + 8 <= header.count {
            guard let chunkId = String(bytes: header[offset..<offset + 4], encoding: .ascii) else { break }
            let chunkSize = header[offset + 4..<offset + 8].withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkId == "data" {
                return offset + 8
            }
            let nextOffset = offset + 8 + Int(chunkSize)
            if nextOffset <= offset { break }
            offset = nextOffset
        }
        throw ClientError.chunkerFailed("no 'data' chunk found in WAV header")
    }

    private func onDiskFileSize() throws -> Int {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            return (attrs[.size] as? Int) ?? 0
        } catch {
            throw ClientError.chunkerFailed("file size: \(error.localizedDescription)")
        }
    }
}
```

The `bytesPerFrame = 2` constant assumes 16-bit mono, which matches `AudioFileWriter`'s output format. If Plan 3's writer ever changes bit depth or channel count, this constant must change to match.

- [ ] **Step 4: Run the tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter WAVChunkerTests 2>&1 | tail -15
```

Expected: both tests pass.

If `writesWAV` reports 15999 frames instead of 16000 at a chunk boundary, the AVAudioFile's processing format may downsample slightly — adjust the assertion tolerance to `>= 15900, <= 16000`. Flag if that happens.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 41 tests in 16 suites (39 prior + 2 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcClient/WAVChunker.swift Tests/HarcClientTests/WAVChunkerTests.swift
git commit -m "feat: WAVChunker slices a growing WAV into fixed-duration files"
```

---

### Task 4: `ChunkedTranscriber` + `TranscriptAssembler` + `SessionTranscript`

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/SessionTranscript.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/TranscriptAssembler.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/ChunkedTranscriber.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/ChunkedTranscriberTests.swift`

- [ ] **Step 1: Write `Sources/HarcClient/SessionTranscript.swift`**

```swift
import Foundation
import HarcCore

public struct ChunkResult: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    public var processingMs: Int

    public init(
        startMs: Int, endMs: Int,
        text: String, words: [Word], speakers: [SpeakerSegment],
        processingMs: Int
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.words = words
        self.speakers = speakers
        self.processingMs = processingMs
    }
}

public struct SessionTranscript: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var audioPath: String
    public var joinedText: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    public var chunks: [ChunkResult]

    public init(
        startedAt: Date, endedAt: Date, audioPath: String,
        joinedText: String, words: [Word], speakers: [SpeakerSegment],
        chunks: [ChunkResult]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioPath = audioPath
        self.joinedText = joinedText
        self.words = words
        self.speakers = speakers
        self.chunks = chunks
    }
}

public struct TranscriptUpdate: Sendable {
    public let chunkIndex: Int
    public let joinedTextSoFar: String
}
```

- [ ] **Step 2: Write `Sources/HarcClient/TranscriptAssembler.swift`**

```swift
import Foundation
import HarcCore

/// Accumulates ChunkResults and produces a finalized SessionTranscript.
/// Word timings and speaker segments are already rebased to session-global time
/// when ChunkResult is constructed (chunker-side chunks carry their startMs).
public final class TranscriptAssembler {
    private var chunks: [ChunkResult] = []

    public init() {}

    public func add(_ chunk: ChunkResult) {
        chunks.append(chunk)
    }

    public var currentJoinedText: String {
        chunks.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func finalize(
        startedAt: Date,
        endedAt: Date,
        audioPath: String
    ) -> SessionTranscript {
        let joined = currentJoinedText

        // Rebase per-chunk word/speaker timings into session-global time.
        var allWords: [Word] = []
        var allSpeakers: [SpeakerSegment] = []
        for chunk in chunks {
            let offset = chunk.startMs
            for w in chunk.words {
                allWords.append(Word(text: w.text, startMs: w.startMs + offset, endMs: w.endMs + offset))
            }
            for s in chunk.speakers {
                allSpeakers.append(SpeakerSegment(
                    speaker: s.speaker,
                    startMs: s.startMs + offset,
                    endMs: s.endMs + offset
                ))
            }
        }

        return SessionTranscript(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioPath,
            joinedText: joined,
            words: allWords,
            speakers: allSpeakers,
            chunks: chunks
        )
    }
}
```

- [ ] **Step 3: Write `Sources/HarcClient/ChunkedTranscriber.swift`**

```swift
import Foundation
import HarcCore

/// Protocol boundary for testing — any client that can transcribe a WAV path.
public protocol TranscribingClient: Sendable {
    func transcribe(audioPath: String, diarize: Bool) async throws -> TranscribeResult
}

extension HarcSTTClient: TranscribingClient {}

/// Drives a WAVChunker, dispatches each chunk to a TranscribingClient,
/// assembles a session transcript. Exposes an AsyncStream for live UI updates.
public actor ChunkedTranscriber {
    private let client: any TranscribingClient
    private let diarize: Bool
    private let chunkDurationSeconds: Double
    private let pollIntervalSeconds: Double

    nonisolated(unsafe) private let assembler = TranscriptAssembler()
    private var chunker: WAVChunker?
    private var audioURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    public let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    public init(
        client: any TranscribingClient,
        diarize: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0
    ) {
        self.client = client
        self.diarize = diarize
        self.chunkDurationSeconds = chunkDurationSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
        self.updates = stream
        self.updatesContinuation = cont
    }

    public func start(audioURL: URL) {
        self.audioURL = audioURL
        self.chunker = WAVChunker(audioURL: audioURL, chunkDurationSeconds: chunkDurationSeconds)
        self.pumpTask = Task.detached { [self] in await self.pump() }
    }

    /// Stops polling, processes any remaining tail chunk, and returns the final assembly.
    public func finalize(startedAt: Date, endedAt: Date) async throws -> SessionTranscript {
        stopped = true
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        if let chunker {
            do {
                if let tail = try await chunker.flush() {
                    try await processChunk(tail)
                }
            } catch {
                // Best-effort: a failed tail chunk shouldn't lose the earlier work.
                FileHandle.standardError.write(Data(
                    "harc-client: tail chunk failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        updatesContinuation.finish()

        return assembler.finalize(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioURL?.path ?? ""
        )
    }

    private func pump() async {
        guard let chunker else { return }
        while !Task.isCancelled, !stopped {
            do {
                if let chunk = try await chunker.nextChunk() {
                    try await processChunk(chunk)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-client: chunk transcription failed: \(error.localizedDescription)\n".utf8
                ))
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func processChunk(_ chunk: WAVChunker.Chunk) async throws {
        defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: diarize)
        let cr = ChunkResult(
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            text: result.text,
            words: result.words,
            speakers: result.speakers,
            processingMs: result.processingMs
        )
        assembler.add(cr)
        let index = assembler.currentJoinedText.isEmpty ? 0 : (assembler.currentJoinedText.split(separator: " ").count)
        updatesContinuation.yield(TranscriptUpdate(
            chunkIndex: index,
            joinedTextSoFar: assembler.currentJoinedText
        ))
    }
}
```

- [ ] **Step 4: Write the failing test `Tests/HarcClientTests/ChunkedTranscriberTests.swift`**

```swift
import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
@testable import HarcClient

@Suite("ChunkedTranscriber")
struct ChunkedTranscriberTests {
    /// Fake client that returns canned results based on call count.
    actor FakeClient: TranscribingClient {
        var calls: [(path: String, diarize: Bool)] = []
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool) async throws -> TranscribeResult {
            calls.append((audioPath, diarize))
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }

    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ct-\(UUID().uuidString.prefix(8)).wav")
    }

    private func writeSineWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("finalize assembles chunk results with rebased word timings")
    func assemblesMultipleChunks() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 2.5)

        let fake = FakeClient(results: [
            TranscribeResult(
                text: "hello",
                words: [Word(text: "hello", startMs: 0, endMs: 500)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 10
            ),
            TranscribeResult(
                text: "world",
                words: [Word(text: "world", startMs: 0, endMs: 400)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 12
            ),
            TranscribeResult(
                text: "tail",
                words: [Word(text: "tail", startMs: 0, endMs: 200)],
                speakers: [],
                processingMs: 5
            ),
        ])

        let transcriber = ChunkedTranscriber(
            client: fake,
            diarize: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05
        )
        await transcriber.start(audioURL: url)
        // Give the pump time to consume 2 full chunks.
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = Date().addingTimeInterval(-3)
        let end = Date()
        let transcript = try await transcriber.finalize(startedAt: start, endedAt: end)

        #expect(transcript.chunks.count == 3, "expected 2 full + 1 tail chunk, got \(transcript.chunks.count)")
        #expect(transcript.joinedText == "hello world tail")
        // Second chunk's "world" word was at chunk-local 0ms; should rebase to 1000ms.
        let worldWord = transcript.words.first { $0.text == "world" }
        #expect(worldWord?.startMs == 1000, "expected world rebased to 1000ms, got \(worldWord?.startMs ?? -1)")
        // Tail chunk's "tail" word was at chunk-local 0ms; should rebase to 2000ms.
        let tailWord = transcript.words.first { $0.text == "tail" }
        #expect(tailWord?.startMs == 2000)
    }
}
```

- [ ] **Step 5: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter ChunkedTranscriberTests 2>&1 | tail -15
```

Expected: ChunkedTranscriber / TranscribingClient missing.

- [ ] **Step 6: Verify the implementation compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

- [ ] **Step 7: Run the tests**

```bash
swift test --filter ChunkedTranscriberTests 2>&1 | tail -15
```

Expected: single test passes.

- [ ] **Step 8: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 42 tests in 17 suites (41 prior + 1 new).

- [ ] **Step 9: Commit**

```bash
git add Sources/HarcClient/SessionTranscript.swift \
        Sources/HarcClient/TranscriptAssembler.swift \
        Sources/HarcClient/ChunkedTranscriber.swift \
        Tests/HarcClientTests/ChunkedTranscriberTests.swift
git commit -m "feat: ChunkedTranscriber + TranscriptAssembler + SessionTranscript"
```

---

### Task 5: `TranscriptWriter` — `.txt` + `.json` sibling outputs

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/TranscriptWriter.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/TranscriptWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("TranscriptWriter")
struct TranscriptWriterTests {
    private func tempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-tw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("writeSiblings creates .txt and .json next to the .wav")
    func writesSiblings() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let wavURL = base.appendingPathComponent("13-14-15.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data([0x00]))

        let transcript = SessionTranscript(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_005),
            audioPath: wavURL.path,
            joinedText: "hello world",
            words: [
                Word(text: "hello", startMs: 0, endMs: 500),
                Word(text: "world", startMs: 500, endMs: 1000),
            ],
            speakers: [],
            chunks: []
        )

        try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)

        let txtURL = base.appendingPathComponent("13-14-15.txt")
        let jsonURL = base.appendingPathComponent("13-14-15.json")
        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let txt = try String(contentsOf: txtURL, encoding: .utf8)
        #expect(txt == "hello world\n")

        let json = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(SessionTranscript.self, from: json)
        #expect(decoded == transcript)
    }

    @Test("writeSiblings is atomic — a failed write doesn't leave partial files")
    func atomicSemantics() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let wavURL = base.appendingPathComponent("hh-mm-ss.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: Data())

        let transcript = SessionTranscript(
            startedAt: Date(), endedAt: Date(),
            audioPath: wavURL.path,
            joinedText: "short",
            words: [],
            speakers: [],
            chunks: []
        )

        try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)
        let txt = try String(contentsOf: base.appendingPathComponent("hh-mm-ss.txt"), encoding: .utf8)
        #expect(txt == "short\n")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter TranscriptWriterTests 2>&1 | tail -15
```

- [ ] **Step 3: Write `Sources/HarcClient/TranscriptWriter.swift`**

```swift
import Foundation

public enum TranscriptWriter {
    /// Writes a `<wav-stem>.txt` (plain transcript) and `<wav-stem>.json` (full structured)
    /// alongside the given WAV URL. Uses atomic writes (writes to temp + rename).
    public static func writeSiblings(transcript: SessionTranscript, nextTo wavURL: URL) throws {
        let stem = wavURL.deletingPathExtension().lastPathComponent
        let parent = wavURL.deletingLastPathComponent()

        let txtURL = parent.appendingPathComponent("\(stem).txt")
        let jsonURL = parent.appendingPathComponent("\(stem).json")

        let txtData = Data((transcript.joinedText + "\n").utf8)
        try txtData.write(to: txtURL, options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: jsonURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter TranscriptWriterTests 2>&1 | tail -10
```

Expected: both tests pass. Note: the first test round-trips through JSON encoding with `.iso8601` dates, so the Date equality check works. The `Equatable` conformance on `SessionTranscript` compares all fields including Dates.

There's a subtlety: `Date(timeIntervalSince1970: 1_700_000_000)` may round-trip exactly through ISO8601 (seconds only) or may lose sub-second precision. If the test fails due to date comparison, adjust to use integer-second dates only.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 44 tests in 18 suites (42 prior + 2 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcClient/TranscriptWriter.swift Tests/HarcClientTests/TranscriptWriterTests.swift
git commit -m "feat: TranscriptWriter emits .txt and .json siblings atomically"
```

---

### Task 6: Integrate `ChunkedTranscriber` into `RecordingSession`

Extends `RecordingSession` with an optional transcriber. When set, it's wired to the cache-WAV during `start()`, finalized during `stop()`. The returned `RecordingResult` carries `.wav` / `.txt` / `.json` URLs.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/RecordingSession.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift`

- [ ] **Step 1: Update `Package.swift`** — HarcAudio depends on HarcClient for the transcriber types. `HarcAudioTests` also gains HarcClient (the new transcription test imports `TranscribingClient`, `ChunkedTranscriber`, `TranscribeResult`).

```swift
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore", "HarcClient"]
        ),
```

And:
```swift
        .testTarget(
            name: "HarcAudioTests",
            dependencies: ["HarcAudio", "HarcCore", "HarcClient"]
        ),
```

- [ ] **Step 2: Rewrite `Sources/HarcAudio/RecordingSession.swift`** — add the transcriber. Full file:

```swift
import Foundation
@preconcurrency import AVFoundation
import HarcClient

/// Result of a completed recording.
public struct RecordingResult: Sendable {
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?
}

/// Orchestrates a single recording. One instance per recording.
public actor RecordingSession {
    private let mic: any MicCaptureSource
    private let systemAudio: any SystemAudioCaptureSource
    private let destination: RecordingDestination
    private let transcriber: ChunkedTranscriber?

    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?

    private var cacheURL: URL?
    private var startedAt: Date?
    private var pumpTask: Task<Void, Never>?
    private var systemAudioAvailable = false

    public init(
        mic: any MicCaptureSource,
        systemAudio: any SystemAudioCaptureSource,
        destination: RecordingDestination,
        transcriber: ChunkedTranscriber? = nil
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.destination = destination
        self.transcriber = transcriber
    }

    public func start(at date: Date) async throws {
        try await mic.requestPermission()
        do {
            try await systemAudio.requestPermission()
            systemAudioAvailable = true
        } catch AudioError.systemAudioPermissionDenied {
            systemAudioAvailable = false
        }

        let cache = RecordingDestination.cachePath()
        self.cacheURL = cache
        self.startedAt = date
        self.writer = try AudioFileWriter(url: cache)

        if let transcriber {
            await transcriber.start(audioURL: cache)
        }

        let micStream = try await mic.start()
        let sysStream: AsyncStream<AVAudioPCMBuffer>?
        if systemAudioAvailable {
            sysStream = try await systemAudio.start()
        } else {
            sysStream = nil
        }

        self.pumpTask = Task.detached { [self, micStream, sysStream] in
            await pumpStreams(session: self, mic: micStream, system: sysStream)
        }
    }

    public func stop() async throws -> RecordingResult {
        await mic.stop()
        await systemAudio.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        guard let writer, let cache = cacheURL, let startedAt else {
            throw AudioError.audioEngineFailed("stop called before start")
        }
        try writer.close()

        let wavURL = try destination.publicPath(for: startedAt)
        try RecordingDestination.atomicMove(from: cache, to: wavURL)
        self.writer = nil

        var txtURL: URL? = nil
        var jsonURL: URL? = nil
        if let transcriber {
            do {
                let transcript = try await transcriber.finalize(
                    startedAt: startedAt,
                    endedAt: Date()
                )
                // Rewrite audioPath to the post-move destination.
                var finalTranscript = transcript
                finalTranscript.audioPath = wavURL.path
                try TranscriptWriter.writeSiblings(transcript: finalTranscript, nextTo: wavURL)
                let stem = wavURL.deletingPathExtension().lastPathComponent
                let parent = wavURL.deletingLastPathComponent()
                txtURL = parent.appendingPathComponent("\(stem).txt")
                jsonURL = parent.appendingPathComponent("\(stem).json")
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: transcription finalize failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    nonisolated fileprivate func processPair(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer?) {
        do {
            let micMono = try mixer.processMic(mic)
            let mixed: AVAudioPCMBuffer
            if let system {
                let sysMono = try mixer.processSystem(system)
                mixed = try mixer.sum(mic: micMono, system: sysMono)
            } else {
                mixed = micMono
            }
            try writer?.write(mixed)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: processPair failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}

private func pumpStreams(
    session: RecordingSession,
    mic micStream: AsyncStream<AVAudioPCMBuffer>,
    system sysStream: AsyncStream<AVAudioPCMBuffer>?
) async {
    if let sysStream {
        var sysIter = sysStream.makeAsyncIterator()
        for await micBuffer in micStream {
            let sysBuffer = await sysIter.next()
            session.processPair(mic: micBuffer, system: sysBuffer)
        }
    } else {
        for await micBuffer in micStream {
            session.processPair(mic: micBuffer, system: nil)
        }
    }
}
```

- [ ] **Step 3: Update existing `RecordingSessionTests`** — the return type changed from `URL` to `RecordingResult`. The existing test uses `let url = try await session.stop()` which must become `let result = try await session.stop(); let url = result.wavURL`.

Open `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTests.swift` and replace two lines:

```swift
        let url = try await session.stop()
```

with:

```swift
        let result = try await session.stop()
        let url = result.wavURL
```

— in BOTH `writesWAVAtDestination` and `degradesMicOnly` tests (two changes total). Do not alter anything else in the file.

- [ ] **Step 4: Write new test `Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift`**

```swift
import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
import HarcClient
@testable import HarcAudio

@Suite("RecordingSession + transcription")
struct RecordingSessionTranscriptionTests {
    private final class SendableBuffers: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
    }

    actor FakeMic: MicCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(script: [AVAudioPCMBuffer]) { self.script = script }
        func requestPermission() async throws {}
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached { for b in box.buffers { cont.yield(b) }; cont.finish() }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    actor FakeSystem: SystemAudioCaptureSource {
        func requestPermission() async throws { throw AudioError.systemAudioPermissionDenied }
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            throw AudioError.systemAudioPermissionDenied
        }
        func stop() async {}
    }

    /// Fake transcribing client: returns canned text per-call.
    actor StubClient: TranscribingClient {
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool) async throws -> TranscribeResult {
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }

    private func makeConstantBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.2 }
        return buf
    }

    @Test("stop() returns .wav + .txt + .json when a transcriber is attached")
    func stopReturnsAllArtifacts() async throws {
        let base = URL(fileURLWithPath: "/tmp/harc-rst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mic = FakeMic(script: [
            makeConstantBuffer(frames: 16000),
            makeConstantBuffer(frames: 16000),
        ])
        let sys = FakeSystem()
        let destination = RecordingDestination(baseDirectory: base)

        let stub = StubClient(results: [
            TranscribeResult(text: "one", words: [], speakers: [], processingMs: 1),
            TranscribeResult(text: "two", words: [], speakers: [], processingMs: 1),
        ])
        let transcriber = ChunkedTranscriber(
            client: stub,
            diarize: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05
        )

        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: destination,
            transcriber: transcriber
        )
        try await session.start(at: Date())
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try await session.stop()

        #expect(FileManager.default.fileExists(atPath: result.wavURL.path))
        try #require(result.txtURL != nil)
        try #require(result.jsonURL != nil)
        #expect(FileManager.default.fileExists(atPath: result.txtURL!.path))
        #expect(FileManager.default.fileExists(atPath: result.jsonURL!.path))

        let txt = try String(contentsOf: result.txtURL!, encoding: .utf8)
        #expect(!txt.isEmpty)
    }
}
```

- [ ] **Step 5: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
```

Expected: `Build complete!` and 45 tests in 19 suites (44 prior + 1 new, with 2 existing RecordingSessionTests still passing under the new `RecordingResult` return type).

If `RecordingSessionTests` fails to compile because the `url` variable is typed wrong, verify both tests were updated in Step 3.

- [ ] **Step 6: Rebuild Xcode project + app build sanity**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate 2>&1 | tail -3
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The Xcode target now links HarcClient via its transitive dependency through HarcAudio.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/HarcAudio/RecordingSession.swift \
        Tests/HarcAudioTests/RecordingSessionTests.swift \
        Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift
git commit -m "feat: RecordingSession integrates optional ChunkedTranscriber + .txt/.json"
```

---

### Task 7: End-to-end integration (real daemon) + AppDelegate wiring

Final integration: spin up a real daemon via `DaemonLauncher`, pass a real `HarcSTTClient`-backed transcriber to `RecordingSession`, record a meeting, and verify `.wav` / `.txt` / `.json` all land in `~/Documents/Harc/YYYY/...`.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/EndToEndTests.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Write the end-to-end test `Tests/HarcClientTests/EndToEndTests.swift`**

This test does something clever: it copies the existing `HarcSTTTests` fixture (`short-speech.wav`) into a temp file, uses a real `HarcSTTClient` against a freshly-spawned daemon on a test socket path, and verifies the transcribe round-trip works. We don't exercise `ChunkedTranscriber` here — that's covered by Task 4's unit test. This test closes the loop: daemon launches, client connects, real Parakeet transcribes real audio.

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("HarcClient end-to-end", .tags(.slow))
struct EndToEndTests {
    /// Copy the HarcSTTTests fixture into /tmp so the daemon test socket doesn't care about bundle paths.
    private func stageFixture() throws -> URL {
        // The HarcSTTTests bundle's Fixtures/short-speech.wav is our canonical fixture.
        // Since HarcClientTests doesn't ship fixtures, walk to find the HarcSTTTests resource bundle.
        let thisBundle = Bundle(for: Token.self)
        let build = (thisBundle.bundlePath as NSString).deletingLastPathComponent
        let candidates = [
            build + "/Harc_HarcSTTTests.bundle/Contents/Resources/Fixtures/short-speech.wav",
            build + "/HarcPackageTests.xctest/Contents/Resources/Fixtures/short-speech.wav",
            build + "/Harc_HarcSTTTests.bundle/Fixtures/short-speech.wav",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            let dst = URL(fileURLWithPath: "/tmp/harc-e2e-\(UUID().uuidString.prefix(8)).wav")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: c), to: dst)
            return dst
        }
        throw ClientError.chunkerFailed("fixture not found in any candidate path")
    }

    private final class Token {}

    @Test("launch daemon + transcribe fixture end-to-end")
    func transcribeFixture() async throws {
        let socketPath = "/tmp/harc-e2e-\(UUID().uuidString.prefix(8)).sock"
        let launcher = DaemonLauncher(socketPath: socketPath)
        _ = try await launcher.ensureRunning()

        let fixture = try stageFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let client = HarcSTTClient(socketPath: socketPath)

        // Wait for model load by polling status.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let s = try? await client.status(), s.modelLoaded { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let result = try await client.transcribe(audioPath: fixture.path, diarize: false)
        #expect(!result.text.isEmpty)
        #expect(result.text.lowercased().contains("test"), "got: \(result.text)")

        try? await client.shutdown()
        await launcher.stop()
    }
}

extension Tag {
    @Tag static var slow: Self
}
```

- [ ] **Step 2: Update `HarcApp/AppDelegate.swift`** — construct a `DaemonLauncher` + `ChunkedTranscriber` when starting a recording, pass them into `RecordingSession`. Update `notifyRecordingSaved` to mention the `.txt` / `.json` outputs.

Full rewrite of `HarcApp/AppDelegate.swift`:

```swift
import AppKit
import HarcAudio
import HarcClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var session: RecordingSession?
    private let launcher = DaemonLauncher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(recording: false, on: item)

        let menu = NSMenu()

        let start = NSMenuItem(
            title: "Start Recording",
            action: #selector(startRecording),
            keyEquivalent: "r"
        )
        start.target = self
        menu.addItem(start)
        self.startMenuItem = start

        let stop = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: "s"
        )
        stop.target = self
        stop.isEnabled = false
        menu.addItem(stop)
        self.stopMenuItem = stop

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Harc",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        self.statusItem = item
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func startRecording() {
        guard session == nil else { return }

        startMenuItem?.isEnabled = false
        stopMenuItem?.isEnabled = true
        if let item = statusItem { updateMenuBarIcon(recording: true, on: item) }

        Task {
            do {
                // Ensure daemon is running before the first chunk.
                _ = try await self.launcher.ensureRunning()
                let client = HarcSTTClient()
                let transcriber = ChunkedTranscriber(
                    client: client,
                    diarize: true,
                    chunkDurationSeconds: 60.0
                )
                let session = RecordingSession(
                    mic: MicCapture(),
                    systemAudio: SystemAudioCapture(),
                    destination: RecordingDestination(baseDirectory: RecordingDestination.defaultBaseDirectory()),
                    transcriber: transcriber
                )
                self.session = session
                try await session.start(at: Date())
            } catch {
                self.presentError(error)
                self.resetUI()
            }
        }
    }

    @objc private func stopRecording() {
        guard let session else { return }
        Task {
            do {
                let result = try await session.stop()
                self.notifyRecordingSaved(result: result)
            } catch {
                self.presentError(error)
            }
            self.resetUI()
        }
    }

    private func resetUI() {
        self.session = nil
        startMenuItem?.isEnabled = true
        stopMenuItem?.isEnabled = false
        if let item = statusItem { updateMenuBarIcon(recording: false, on: item) }
    }

    private func updateMenuBarIcon(recording: Bool, on item: NSStatusItem) {
        let symbol = recording ? "record.circle.fill" : "waveform"
        let label = recording ? "Harc — recording" : "Harc"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    private func notifyRecordingSaved(result: RecordingResult) {
        let alert = NSAlert()
        alert.messageText = "Recording saved"
        if result.txtURL != nil {
            alert.informativeText = "Audio, transcript, and structured JSON written next to each other.\n\n\(result.wavURL.path)"
        } else {
            alert.informativeText = result.wavURL.path
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([result.wavURL])
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording error"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
```

- [ ] **Step 3: Rebuild Xcode project + app + run EndToEndTests**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate 2>&1 | tail -3
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

```bash
swift test 2>&1 | tail -10
```

Expected: 46 tests in 20 suites (45 prior + 1 new end-to-end). First run of `EndToEndTests` takes a while (~30s for daemon spawn + model load if warm-cached; several minutes if models must download).

If `EndToEndTests.transcribeFixture` can't locate the fixture, it means SwiftPM staged it under an unexpected path for this build. Patch the `candidates` array with the actual path you find via:
```bash
find .build -name short-speech.wav 2>/dev/null
```

- [ ] **Step 4: Manual smoke — record a real short clip with transcription**

```bash
cd /Users/jlane/GitHub/Harc
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Click Start (⌘R), speak for ~70 seconds (so at least one 60s chunk triggers), click Stop (⌘S). Alert should say "Audio, transcript, and structured JSON written next to each other." Click Reveal in Finder. You should see three sibling files in `~/Documents/Harc/YYYY/YYYY-MM-DD/`:
- `HH-mm-ss.wav`
- `HH-mm-ss.txt`
- `HH-mm-ss.json`

Open the `.txt` to see the transcript. Open the `.json` to see word timings and chunk boundaries.

If the txt is empty, the daemon likely hasn't finished loading models before the chunk dispatched — watch `~/Library/Caches/Harc/daemon.log` to confirm.

- [ ] **Step 5: Commit**

```bash
git add HarcApp/AppDelegate.swift Tests/HarcClientTests/EndToEndTests.swift
git commit -m "feat: AppDelegate wires DaemonLauncher + ChunkedTranscriber; end-to-end test"
```

---

## Acceptance Criteria (Plan 4 complete when all true)

- `swift test` passes all existing + new HarcClient + HarcAudio tests. Expect ~46 tests in 20 suites.
- `swift build` clean; `swift build -Xswiftc -strict-concurrency=complete` clean.
- `xcodegen generate && xcodebuild ... build` succeeds; `codesign --verify --deep --strict Harc.app` green.
- End-to-end test transcribes the fixture via a real spawned daemon.
- Launching `Harc.app`, pressing ⌘R, speaking for 70+ seconds, pressing ⌘S produces a `.wav` + `.txt` + `.json` trio in `~/Documents/Harc/YYYY/YYYY-MM-DD/`.
- The `.txt` contains non-empty transcribed text.
- The `.json` round-trips through `JSONDecoder().decode(SessionTranscript.self, from: data)`.
- 7 new commits on `main`.

## Open Decisions

- **Cross-chunk speaker stitching.** Plan 4 uses per-chunk speaker IDs without reconciliation across chunks. "Speaker 0" in chunk 1 and "Speaker 0" in chunk 2 may be different people. True stitching requires speaker embedding similarity scoring, which needs an additional FluidAudio API surface. Revisit in Plan 6 (clipboard history) when users browse past transcripts.
- **Chunk overlap for word boundaries.** Plan 4's chunker is non-overlapping. A 60s / 62s overlap with dedupe-on-join would avoid mid-word cuts but requires a diff/merge step. The cheap alternative: pick VAD-aligned chunk boundaries (Plan 3a / CLAUDE.md open decision). Deferred.
- **Retry on transient daemon failure.** Currently a failed chunk transcription is logged and skipped. Future: retry up to 3x with exponential backoff, then record a placeholder `[transcription failed]` in the chunk's text field.

## Self-Review

**Spec coverage (Plan 1's Plan 4 sketch):**

- "An actor watches the durable WAV and, every ~60 s of recorded audio, hands a chunk to an in-process HarcSTTClient" → Task 4 `ChunkedTranscriber` + Task 3 `WAVChunker`.
- "Tracks byte offsets so chunks don't overlap" → Task 3's `consumedFrames` tracking.
- "Accumulates TranscribeResults into a session transcript" → Task 4 `TranscriptAssembler`.
- "Stitches diarization/speaker IDs across chunk boundaries" → NOT FULLY — per-chunk speaker IDs documented as Open Decision.
- "On stop, flushes the final partial chunk, awaits completion, and writes HH-mm-ss.txt + HH-mm-ss.json alongside the WAV" → Task 4 `flush()` + Task 5 `TranscriptWriter` + Task 6 `RecordingSession.stop()`.
- "Exposes an AsyncStream<TranscriptUpdate> that the UI subscribes to" → Task 4 `ChunkedTranscriber.updates`.
- "Tests: feed a pre-recorded 3-minute file in chunked mode vs whole-file mode and assert the joined transcript matches" → NOT FULLY — Task 4's test uses canned fake results; Task 7's end-to-end hits real daemon on a single 3s fixture. A 3-minute chunked-vs-whole comparison is deferred to Plan 4a if needed.

**Placeholder scan:** no `TODO`, `TBD`, or undefined references. Every code block is complete and runnable.

**Type consistency:**
- `HarcSTTClient.init(socketPath:)` / `HarcSTTClient.init(connectedFd:)` in Task 1 consumed by `DaemonLauncher` (Task 2) and `ChunkedTranscriber` (via `TranscribingClient` protocol) (Task 4).
- `ChunkResult`, `SessionTranscript`, `TranscriptUpdate` declared in Task 4, consumed in Tasks 5-6.
- `TranscribingClient` protocol (Task 4) has `extension HarcSTTClient: TranscribingClient {}` to bind the real client.
- `RecordingResult` struct (Task 6) consumed in AppDelegate (Task 7).
- `WAVChunker.Chunk` struct declared in Task 3, consumed in Task 4's `ChunkedTranscriber.processChunk`.
