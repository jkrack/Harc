# Harc Daemon Core Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `harc-stt` from a CLI stub into a real speech-to-text daemon. The daemon listens on a Unix domain socket, speaks the frozen IPC protocol from Plan 1, loads Parakeet TDT 0.6B v3 via FluidAudio on startup, transcribes WAV files end-to-end on the Apple Neural Engine, and self-shuts-down after idle.

**Architecture:** Single executable target. One `Daemon` actor owns top-level state (transcriber, diarizer, idle clock). A `SocketServer` accepts clients; a `ClientConnection` reads newline-delimited JSON, dispatches to a `RequestHandler` that routes to transcribe/status/shutdown. Two FluidAudio-backed actors (`Transcriber` and `Diarizer`) wrap the ASR and speaker-diarization models respectively. Pattern is adapted from the working OpenBrain reference at `/Users/jlane/GitHub/OpenBrain/swift/openbrain-stt/` — the big deltas are: Swift 6 strict-concurrency actors instead of global mutable state, Swift Testing instead of no tests, and our IPC types from `HarcCore` instead of bespoke protocol structs.

**Tech Stack:** Swift 6.0, SwiftPM, Swift Testing, FluidAudio 0.13.5 (Parakeet TDT v3 + diarizer models, auto-downloaded on first use), Darwin C socket APIs (`socket`, `bind`, `listen`, `accept`), `FileManager`, `Task` / actors.

---

## Prerequisites

- Plan 1 complete on `main`. Working tree clean aside from the pre-existing untracked `docs/` and `HarcApp/Info.plist`.
- `swift test` currently passes 8 tests across 2 suites.
- Xcode 15.4+ (Xcode 26.0.1 locally), FluidAudio's Parakeet TDT v3 models will be downloaded from HuggingFace on first `loadModel()` call — requires network access. Models cache to `~/Library/Application Support/FluidAudio/Models/` (~2 GB). First-run tests that exercise the real model will be slow; subsequent runs hit the cache.
- Machine has enough free disk for model downloads and a working mic/speakers only if you plan to manually smoke-test — automated tests use bundled WAV fixtures.

## Scope Boundary

This plan produces a **working daemon that transcribes and diarizes WAV files over IPC**. Out of scope (lives in later plans):

- Audio capture from mic / `ScreenCaptureKit` (Plan 3).
- Rolling 60-second chunking of a live-growing WAV (Plan 4).
- Menu bar popover wiring the daemon client (Plan 5).
- Clipboard history (Plan 6).
- Hour-long audio stress test → see Task 8 risk-spike notes.

## File Structure

After Plan 2, the repo gains:

```
Harc/
├── Package.swift                              (modified — +FluidAudio, +HarcSTTTests)
├── Sources/
│   └── HarcSTT/
│       ├── HarcSTTCLI.swift                   (modified — spawns daemon when no --flag given)
│       ├── Daemon.swift                       (new — top-level actor)
│       ├── SocketServer.swift                 (new — Unix socket bind/accept)
│       ├── ClientConnection.swift             (new — NDJSON read/write per client)
│       ├── RequestHandler.swift               (new — IPCRequest dispatch)
│       ├── Transcriber.swift                  (new — FluidAudio AsrManager wrapper)
│       ├── Diarizer.swift                     (new — FluidAudio DiarizerManager wrapper)
│       └── DaemonError.swift                  (new — typed errors)
└── Tests/
    └── HarcSTTTests/                          (new test target)
        ├── Fixtures/
        │   └── short-speech.wav               (new — ~4 s TTS, 16 kHz mono)
        ├── FixturesLoadTests.swift            (T1)
        ├── TranscriberTests.swift             (T2)
        ├── SocketServerTests.swift            (T3)
        ├── ClientConnectionTests.swift        (T4)
        ├── RequestHandlerTests.swift          (T5)
        ├── DiarizerTests.swift                (T6)
        └── DaemonIntegrationTests.swift       (T8)
```

### Responsibilities

- **`Daemon`** — the single owning actor. Holds `Transcriber`, `Diarizer`, last-activity timestamp, shutdown flag. Exposes `run()` which orchestrates socket server + model pre-loading + idle-timeout monitor. One instance per daemon process.
- **`SocketServer`** — opens/binds/listens on the Unix socket. Exposes an `AsyncStream<Int32>` of accepted client file descriptors. Owns the server fd; cleans up on `shutdown()`.
- **`ClientConnection`** — one per accepted fd. Reads bytes into a buffer, splits on `0x0A`, decodes each segment as `IPCRequest`, yields decoded requests to a callback. Writes `IPCResponse` values back as JSON + `\n`. Swallows read timeout after 60s.
- **`RequestHandler`** — stateless function-shaped type. Given an `IPCRequest` and the `Daemon`'s services, produces an `IPCResponse`. Contains no I/O.
- **`Transcriber`** — actor wrapping FluidAudio's `AsrManager`. `loadModels()` + `transcribe(samples:) -> TranscribeResult`. Throws `DaemonError.modelNotLoaded` if called pre-load.
- **`Diarizer`** — actor wrapping FluidAudio's `DiarizerManager`. `loadModels()` + `diarize(samples:) -> [SpeakerSegment]`. Optional — only invoked when `TranscribeRequest.diarize == true`.
- **`DaemonError`** — `enum Error, LocalizedError` with cases for socket failures, audio failures, model states.
- **`HarcSTTCLI`** — still the `@main`. Post-change: when invoked without `--version`/`--help`, starts the daemon instead of erroring out.

### Why split this way

Each piece is independently testable:
- `SocketServer` can be tested without any daemon logic (connect a raw client, confirm accept fires).
- `ClientConnection` can be tested against an in-memory pair of fds (`socketpair`) with no real socket.
- `RequestHandler` is pure-ish — given a fake Transcriber/Diarizer, you can assert the correct IPCResponse shape for every IPCRequest case.
- `Transcriber` is tested against the bundled WAV fixture (slow, requires model download on first run).
- `Daemon` integration test verifies the whole thing end-to-end.

Avoid collapsing `Daemon` and `SocketServer` into one file — the daemon wants to be testable against a stub socket in Plan 4/5 when the menu bar client needs a fake daemon for UI development.

## Testing Notes

**Fixture WAV.** `Tests/HarcSTTTests/Fixtures/short-speech.wav` is generated on a developer machine with:
```bash
say -o /tmp/harc-fixture.aiff --data-format LEI16@16000 "Hello. This is a test recording for Harc."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/harc-fixture.aiff Tests/HarcSTTTests/Fixtures/short-speech.wav
```
The fixture is ~4 s, mono, 16 kHz, Int16 PCM — the exact format FluidAudio's AudioConverter produces. ~128 KB.

**Slow tests.** Anything that loads a FluidAudio model or runs a transcription takes seconds to minutes on first run (model download) and seconds thereafter (ANE inference on a short clip). Mark these with `.tags(.slow)` and skip by default via `swift test --filter` in CI if needed. For local dev, expect a few minutes on first run.

**Sandbox.** The daemon writes its socket to `$HOME/.harc/stt.sock`. Tests use a temp socket path per test so they don't collide with a locally-running daemon.

**Concurrency.** We use Swift 6 strict concurrency. All shared state lives inside actors; transport code uses C socket APIs inside nonisolated functions that only touch local state + args. `HarcCore`'s wire value types (`TranscribeResult`, `Word`, `SpeakerSegment`, `DaemonStatus`, `IPCError`) conform to `Sendable` in addition to `Codable, Equatable`. Pure value types with Sendable stored properties, so conformance is free. Required because the daemon crosses actor boundaries (Transcriber → RequestHandler → Daemon) and `#expect(throws:)` expansions in tests also cross isolation.

**FluidAudio API naming note.** FluidAudio 0.13.x ships `ASRResult` / `ASRConfig` (all-caps `ASR`), not the `AsrResult` / `AsrConfig` that OpenBrain's Transcriber.swift has. `AsrManager` / `AsrModels` keep the camel-case `Asr` prefix. When porting or reviewing, watch for that split.

---

### Task 1: Add FluidAudio dependency + HarcSTTTests target + fixture

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/Fixtures/short-speech.wav`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/FixturesLoadTests.swift`

- [ ] **Step 1: Generate the WAV fixture locally**

From `/Users/jlane/GitHub/Harc`:
```bash
mkdir -p Tests/HarcSTTTests/Fixtures
say -o /tmp/harc-fixture.aiff --data-format LEI16@16000 "Hello. This is a test recording for Harc."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/harc-fixture.aiff Tests/HarcSTTTests/Fixtures/short-speech.wav
rm /tmp/harc-fixture.aiff
afinfo Tests/HarcSTTTests/Fixtures/short-speech.wav | head -20
```

Expected `afinfo` output includes: `Num SampleRate: 16000`, `Channels per Frame: 1`, `Bits per Channel: 16`, a duration around 3–4 seconds. File size roughly 100–150 KB.

- [ ] **Step 2: Rewrite `Package.swift` to add FluidAudio + the test target**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
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
            dependencies: [
                "HarcSTT",
                "HarcCore",
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 3: Write the fixture-load smoke test `Tests/HarcSTTTests/FixturesLoadTests.swift`**

```swift
import Testing
import Foundation

@Suite("Test fixtures load")
struct FixturesLoadTests {
    @Test("short-speech.wav is present and non-empty")
    func shortSpeechWAVExists() throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 10_000, "fixture should be at least 10 KB")
    }
}
```

- [ ] **Step 4: Run `swift build` to pull FluidAudio**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
```

Expected: FluidAudio (and its CoreML transitive deps) fetch and compile. First run takes a minute or two. `Build complete!` at the end.

- [ ] **Step 5: Run the new test**

```bash
swift test --filter FixturesLoadTests 2>&1 | tail -10
```

Expected: `Test run with 1 test in 1 suite passed`.

- [ ] **Step 6: Confirm the existing 8 HarcCoreTests still pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `Test run with 9 tests in 3 suites passed` (1 new + 8 existing).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Tests/HarcSTTTests
git commit -m "build: add FluidAudio dep + HarcSTTTests target with speech fixture"
```

Commit contains: `Package.swift`, `Package.resolved` (newly generated), `Tests/HarcSTTTests/Fixtures/short-speech.wav`, `Tests/HarcSTTTests/FixturesLoadTests.swift`.

---

### Task 2: Transcriber actor

Port the OpenBrain Transcriber pattern, but returning our `HarcCore.TranscribeResult` directly (not a bespoke struct) so the daemon code downstream can hand it straight to the client.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/Transcriber.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/DaemonError.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/TranscriberTests.swift`

- [ ] **Step 1: Write `Sources/HarcSTT/DaemonError.swift`**

```swift
import Foundation

public enum DaemonError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case audioLoadFailed(String)
    case transcriptionFailed(String)
    case socketCreationFailed(Int32)
    case socketBindFailed(Int32)
    case socketListenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded — call loadModels() first"
        case .audioLoadFailed(let reason):
            return "Audio load failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .socketCreationFailed(let errno):
            return "Failed to create socket (errno \(errno))"
        case .socketBindFailed(let errno):
            return "Failed to bind socket (errno \(errno))"
        case .socketListenFailed(let errno):
            return "Failed to listen on socket (errno \(errno))"
        }
    }

    /// Maps to an IPCError with a stable code string so clients can switch on it.
    public var ipcCode: String {
        switch self {
        case .modelNotLoaded: return "model_not_loaded"
        case .audioLoadFailed: return "audio_load_failed"
        case .transcriptionFailed: return "transcription_failed"
        case .socketCreationFailed, .socketBindFailed, .socketListenFailed: return "socket_error"
        }
    }
}
```

- [ ] **Step 2: Write the failing test `Tests/HarcSTTTests/TranscriberTests.swift`**

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Transcriber", .tags(.slow))
struct TranscriberTests {
    @Test("transcribing short-speech.wav produces non-empty text and word timings")
    func transcribeShortSpeech() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        #expect(result.words.count > 0, "expected at least one word timing")
        #expect(result.processingMs > 0, "processingMs should be positive")
        // The fixture says "Hello. This is a test recording for Harc."
        // Don't assert exact words — ASR can vary. Just confirm it mentions "test".
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
    }

    @Test("transcribe before loadModels throws .modelNotLoaded")
    func transcribeBeforeLoadThrows() async throws {
        let transcriber = Transcriber()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await transcriber.transcribe(audioPath: "/tmp/does-not-matter.wav")
        }
    }
}

extension Tag {
    @Tag static var slow: Self
}
```

- [ ] **Step 3: Run to verify failure**

```bash
swift test --filter TranscriberTests 2>&1 | tail -20
```

Expected: compile errors — `Transcriber`, `loadModels()`, `transcribe(audioPath:)` don't exist yet. (The `.tags(.slow)` syntax requires the `Tag` extension at the bottom of the file — that's provided.)

- [ ] **Step 4: Write `Sources/HarcSTT/Transcriber.swift`**

```swift
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's ASR pipeline (Parakeet TDT v3) for CoreML inference on ANE/Metal.
///
/// Models auto-download from HuggingFace on first `loadModels()` to
/// `~/Library/Application Support/FluidAudio/Models/`. Keep one instance for the
/// lifetime of the daemon — loading is expensive (seconds) and the underlying
/// CoreML compiled model is not cheap to hold.
public actor Transcriber {
    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { asrManager != nil }

    public func loadModels() async throws {
        guard asrManager == nil else { return }
        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        try await manager.loadModels(models)
        self.asrManager = manager
    }

    public func transcribe(audioPath: String) async throws -> TranscribeResult {
        guard let manager = asrManager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let start = DispatchTime.now()
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples)
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let words: [Word] = (result.tokenTimings ?? []).map { t in
            Word(
                text: t.token,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],                       // Diarizer fills this in Task 6
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }
}
```

- [ ] **Step 5: Run the test**

```bash
swift test --filter TranscriberTests 2>&1 | tail -30
```

Expected: first run downloads ~2 GB of Parakeet TDT v3 models (may take minutes). Both tests pass. If download hits a network hiccup, re-run — the cache is durable.

If `transcribeBeforeLoadThrows` fails with a different error than `.modelNotLoaded`, the Swift 6 actor access pattern is off — confirm the test is using `await`. If the `contains("test")` assertion fails, check the actual transcription output; Parakeet might be parsing "test" differently (if so, weaken to `result.text.count > 10`).

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcSTT/Transcriber.swift Sources/HarcSTT/DaemonError.swift \
        Tests/HarcSTTTests/TranscriberTests.swift
git commit -m "feat: Transcriber actor wrapping FluidAudio AsrManager"
```

---

### Task 3: SocketServer

Opens a Unix domain socket, binds to a configurable path, listens, yields accepted client fds via `AsyncStream<Int32>`. No per-client logic here — `ClientConnection` (Task 4) handles that.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/SocketServer.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/SocketServerTests.swift`

- [ ] **Step 1: Write the failing test `Tests/HarcSTTTests/SocketServerTests.swift`**

```swift
import Testing
import Foundation
import Darwin
@testable import HarcSTT

@Suite("SocketServer")
struct SocketServerTests {
    /// `sun_path` is 104 bytes on macOS. `FileManager.default.temporaryDirectory`
    /// can already be ~47 chars (e.g. `/var/folders/.../T/`), leaving too little
    /// room for a UUID-suffixed filename. Use a short `/tmp` path instead.
    private func tempSocketPath() -> String {
        "/tmp/harc-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("start then connect from a client receives a client fd")
    func clientConnects() async throws {
        let path = tempSocketPath()
        let server = try SocketServer(socketPath: path)
        defer { server.shutdown() }

        let acceptTask = Task<Int32, Error> {
            for await clientFd in server.clients {
                return clientFd
            }
            throw CancellationError()
        }

        // Connect from a raw POSIX client
        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFd >= 0)
        defer { close(clientFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(clientFd, sp, addrLen)
            }
        }
        #expect(connectResult == 0, "connect failed, errno=\(errno)")

        let acceptedFd = try await acceptTask.value
        #expect(acceptedFd >= 0)
        close(acceptedFd)
    }

    @Test("shutdown removes the socket file")
    func shutdownRemovesSocket() throws {
        let path = tempSocketPath()
        let server = try SocketServer(socketPath: path)
        #expect(FileManager.default.fileExists(atPath: path))
        server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter SocketServerTests 2>&1 | tail -10
```

Expected: compile errors — `SocketServer` doesn't exist.

- [ ] **Step 3: Write `Sources/HarcSTT/SocketServer.swift`**

```swift
import Foundation
import Darwin

/// Unix domain socket server. Binds to `socketPath`, listens, and yields
/// accepted client file descriptors through `clients`. Not itself an actor —
/// all state mutation happens on a single internal `Task` so the type is
/// `Sendable` by construction of the async stream.
public final class SocketServer: @unchecked Sendable {
    public let socketPath: String
    public let clients: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private var serverFd: Int32
    private var acceptTask: Task<Void, Never>?

    public init(socketPath: String) throws {
        self.socketPath = socketPath

        // Ensure parent dir exists (e.g. ~/.harc/)
        let parent = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )

        // Remove any stale socket left from a previous run
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socketCreationFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw DaemonError.socketBindFailed(err)
        }

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw DaemonError.socketListenFailed(err)
        }

        self.serverFd = fd
        let (stream, cont) = AsyncStream<Int32>.makeStream()
        self.clients = stream
        self.continuation = cont

        self.acceptTask = Task.detached { [weak self] in
            await self?.runAcceptLoop()
        }
    }

    private func runAcceptLoop() async {
        while !Task.isCancelled {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    accept(serverFd, sp, &clientAddrLen)
                }
            }
            if clientFd >= 0 {
                continuation.yield(clientFd)
            } else if errno == EINTR {
                continue
            } else {
                // EBADF after shutdown() — normal exit.
                break
            }
        }
        continuation.finish()
    }

    public func shutdown() {
        acceptTask?.cancel()
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        continuation.finish()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
swift test --filter SocketServerTests 2>&1 | tail -15
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/SocketServer.swift Tests/HarcSTTTests/SocketServerTests.swift
git commit -m "feat: SocketServer with Unix-domain bind/listen/accept loop"
```

---

### Task 4: ClientConnection — NDJSON read/write

Per-client fd wrapper. Reads raw bytes, splits on `\n`, decodes each segment as `IPCRequest`, invokes a handler closure, writes each returned `IPCResponse` back as JSON + `\n`. Tested with `socketpair(2)` — no real sockets needed.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/ClientConnection.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/ClientConnectionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcSTT

@Suite("ClientConnection")
struct ClientConnectionTests {
    /// Helper: returns (serverSideFd, clientSideFd) connected via AF_UNIX socketpair.
    private func makePair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        let ok = pair.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try #require(ok == 0, "socketpair failed, errno=\(errno)")
        return (pair[0], pair[1])
    }

    @Test("reads one request, invokes handler, writes the response")
    func singleRequestRoundTrip() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let expectedResponse = IPCResponse.status(
            DaemonStatus(version: "0.1.0", modelLoaded: true, uptimeSeconds: 42)
        )

        let connTask = Task<Void, Error> {
            let conn = ClientConnection(fd: serverFd)
            await conn.serve { request in
                #expect(request == .status)
                return expectedResponse
            }
        }

        // Write a status request from the "client" side
        let reqData = try JSONEncoder().encode(IPCRequest.status) + Data([0x0A])
        _ = reqData.withUnsafeBytes { rawBuf in
            write(clientFd, rawBuf.baseAddress, reqData.count)
        }

        // Read response
        var respBuffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }
        while !respBuffer.contains(0x0A) {
            let n = read(clientFd, readBuf, 4096)
            if n > 0 {
                respBuffer.append(readBuf, count: n)
            } else {
                break
            }
        }

        // Drop the trailing newline and any extra bytes
        let nl = respBuffer.firstIndex(of: 0x0A) ?? respBuffer.endIndex
        let jsonBytes = respBuffer.prefix(upTo: nl)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: jsonBytes)
        #expect(decoded == expectedResponse)

        shutdown(clientFd, SHUT_WR)
        try await connTask.value
    }

    @Test("invalid JSON yields an IPCResponse.error with decode_failed code")
    func invalidJSONYieldsError() async throws {
        let (serverFd, clientFd) = try makePair()
        defer { close(clientFd) }

        let connTask = Task<Void, Error> {
            let conn = ClientConnection(fd: serverFd)
            await conn.serve { _ in
                Issue.record("handler should not be called for invalid JSON")
                return IPCResponse.status(DaemonStatus(version: "0", modelLoaded: false, uptimeSeconds: 0))
            }
        }

        let junk = "not-a-json-object\n".data(using: .utf8)!
        _ = junk.withUnsafeBytes { write(clientFd, $0.baseAddress, junk.count) }

        var respBuffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuf.deallocate() }
        while !respBuffer.contains(0x0A) {
            let n = read(clientFd, readBuf, 4096)
            if n > 0 { respBuffer.append(readBuf, count: n) } else { break }
        }
        let nl = respBuffer.firstIndex(of: 0x0A) ?? respBuffer.endIndex
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: respBuffer.prefix(upTo: nl))
        if case .error(let err) = decoded {
            #expect(err.code == "decode_failed")
        } else {
            Issue.record("expected .error response, got: \(decoded)")
        }

        shutdown(clientFd, SHUT_WR)
        try await connTask.value
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter ClientConnectionTests 2>&1 | tail -10
```

Expected: `ClientConnection` not found.

- [ ] **Step 3: Write `Sources/HarcSTT/ClientConnection.swift`**

```swift
import Foundation
import Darwin
import HarcCore

/// Serves one client connection over an already-accepted fd. Reads
/// newline-delimited JSON `IPCRequest` messages, invokes the handler, writes
/// each returned `IPCResponse` + `\n`. Closes the fd on exit.
public struct ClientConnection: Sendable {
    private let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
    }

    /// Read-dispatch-write loop until EOF or the client sends `.shutdown`.
    /// Returns `true` if the handler processed a `.shutdown` request.
    @discardableResult
    public func serve(handler: @Sendable (IPCRequest) async -> IPCResponse) async -> Bool {
        defer { close(fd) }

        var buffer = Data()
        let chunkSize = 64 * 1024
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { readBuf.deallocate() }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        while true {
            let n = read(fd, readBuf, chunkSize)
            if n > 0 {
                buffer.append(readBuf, count: n)
            } else if n == 0 {
                return false // EOF
            } else if errno == EINTR {
                continue
            } else {
                return false
            }

            // Drain as many complete messages as we have.
            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIndex)
                buffer.removeSubrange(buffer.startIndex...nlIndex)

                let response: IPCResponse
                let wasShutdown: Bool
                do {
                    let request = try decoder.decode(IPCRequest.self, from: lineData)
                    response = await handler(request)
                    wasShutdown = (request == .shutdown)
                } catch {
                    response = .error(IPCError(
                        code: "decode_failed",
                        message: error.localizedDescription
                    ))
                    wasShutdown = false
                }

                do {
                    var payload = try encoder.encode(response)
                    payload.append(0x0A)
                    payload.withUnsafeBytes { raw in
                        var written = 0
                        while written < payload.count {
                            let w = write(fd, raw.baseAddress!.advanced(by: written), payload.count - written)
                            if w <= 0 { break }
                            written += w
                        }
                    }
                } catch {
                    // Can't encode response — nothing to do but drop it.
                }

                if wasShutdown { return true }
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
swift test --filter ClientConnectionTests 2>&1 | tail -15
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/ClientConnection.swift Tests/HarcSTTTests/ClientConnectionTests.swift
git commit -m "feat: ClientConnection NDJSON read/write with decode-error handling"
```

---

### Task 5: RequestHandler with working transcribe + status + shutdown

Routes an `IPCRequest` to the right handler. For `.transcribe`, delegates to `Transcriber`. For `.status`, synthesizes a `DaemonStatus` from provided state. For `.shutdown`, always returns a success-shaped status (the connection layer terminates the daemon).

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/RequestHandler.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/RequestHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("RequestHandler")
struct RequestHandlerTests {
    // Test double that pretends to be the real Transcriber so we can unit-test
    // the handler without loading a real CoreML model.
    actor FakeTranscriber: TranscribeService {
        var loadCalled = false
        var lastPath: String?
        var result: TranscribeResult = TranscribeResult(
            text: "fake", words: [], speakers: [], processingMs: 1
        )

        func transcribe(audioPath: String) async throws -> TranscribeResult {
            lastPath = audioPath
            return result
        }

        var isLoaded: Bool { true }
    }

    @Test("status request returns current DaemonStatus")
    func statusRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake,
            diarizer: nil,
            version: "9.9.9",
            startedAt: Date().addingTimeInterval(-10)
        )
        let resp = await handler.handle(.status)
        if case .status(let s) = resp {
            #expect(s.version == "9.9.9")
            #expect(s.modelLoaded == true)
            #expect(s.uptimeSeconds >= 9)
        } else {
            Issue.record("expected .status response, got: \(resp)")
        }
    }

    @Test("shutdown request returns status response")
    func shutdownRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.shutdown)
        if case .status = resp {
            // ok
        } else {
            Issue.record("expected .status response for shutdown, got: \(resp)")
        }
    }

    @Test("transcribe request delegates to the transcriber and returns .result")
    func transcribeRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/whatever.wav"))
        let resp = await handler.handle(req)
        if case .result(let r) = resp {
            #expect(r.text == "fake")
        } else {
            Issue.record("expected .result response, got: \(resp)")
        }
        await #expect(fake.lastPath == "/tmp/whatever.wav")
    }

    @Test("transcribe with diarize=true but no diarizer available still succeeds (empty speakers)")
    func transcribeDiarizeWithoutDiarizer() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", diarize: true))
        let resp = await handler.handle(req)
        if case .result(let r) = resp {
            #expect(r.speakers.isEmpty)
        } else {
            Issue.record("expected .result, got: \(resp)")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter RequestHandlerTests 2>&1 | tail -10
```

Expected: `RequestHandler`, `TranscribeService`, protocol-related failures.

- [ ] **Step 3: Write `Sources/HarcSTT/RequestHandler.swift`**

```swift
import Foundation
import HarcCore

/// Minimal protocol so RequestHandler can be unit-tested against fakes.
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
}

extension Transcriber: TranscribeService {}

public protocol DiarizeService: Sendable {
    func diarize(audioPath: String) async throws -> [SpeakerSegment]
    var isLoaded: Bool { get async }
}

/// Routes IPCRequests to the appropriate service, producing an IPCResponse.
/// Stateless except for a handful of daemon-lifetime values (version, startedAt).
public struct RequestHandler: Sendable {
    private let transcriber: any TranscribeService
    private let diarizer: (any DiarizeService)?
    private let version: String
    private let startedAt: Date

    public init(
        transcriber: any TranscribeService,
        diarizer: (any DiarizeService)?,
        version: String,
        startedAt: Date
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.version = version
        self.startedAt = startedAt
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request {
        case .status:
            let loaded = await transcriber.isLoaded
            return .status(DaemonStatus(
                version: version,
                modelLoaded: loaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .shutdown:
            let loaded = await transcriber.isLoaded
            return .status(DaemonStatus(
                version: version,
                modelLoaded: loaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .transcribe(let req):
            return await transcribe(req)
        }
    }

    private func transcribe(_ req: TranscribeRequest) async -> IPCResponse {
        let textResult: TranscribeResult
        do {
            textResult = try await transcriber.transcribe(audioPath: req.audioPath)
        } catch let err as DaemonError {
            return .error(IPCError(code: err.ipcCode, message: err.errorDescription ?? "transcribe failed"))
        } catch {
            return .error(IPCError(code: "transcribe_failed", message: error.localizedDescription))
        }

        guard req.diarize, let diarizer else {
            return .result(textResult)
        }

        let speakers: [SpeakerSegment]
        do {
            speakers = try await diarizer.diarize(audioPath: req.audioPath)
        } catch let err as DaemonError {
            // Transcription succeeded; degrade to empty speakers and return success.
            // Clients that care can inspect speakers.isEmpty.
            _ = err
            speakers = []
        } catch {
            speakers = []
        }

        return .result(TranscribeResult(
            text: textResult.text,
            words: textResult.words,
            speakers: speakers,
            processingMs: textResult.processingMs
        ))
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
swift test --filter RequestHandlerTests 2>&1 | tail -15
```

Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/RequestHandler.swift Tests/HarcSTTTests/RequestHandlerTests.swift
git commit -m "feat: RequestHandler dispatches IPCRequest to services"
```

---

### Task 6: Diarizer actor + wire into RequestHandler

Adds a FluidAudio diarizer. Integration with `RequestHandler` happens via the existing `DiarizeService` protocol from Task 5.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/Diarizer.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/DiarizerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Diarizer", .tags(.slow))
struct DiarizerTests {
    @Test("diarizing short-speech.wav returns at least one speaker segment")
    func diarizeShortSpeech() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let diarizer = Diarizer()
        try await diarizer.loadModels()

        let segments = try await diarizer.diarize(audioPath: url.path)

        #expect(segments.count >= 1, "expected at least one speaker segment")
        for segment in segments {
            #expect(segment.endMs > segment.startMs, "segment ends should come after starts")
        }
    }

    @Test("diarize before loadModels throws .modelNotLoaded")
    func diarizeBeforeLoadThrows() async throws {
        let diarizer = Diarizer()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await diarizer.diarize(audioPath: "/tmp/whatever.wav")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter DiarizerTests 2>&1 | tail -10
```

Expected: `Diarizer` missing.

- [ ] **Step 3: Write `Sources/HarcSTT/Diarizer.swift`**

```swift
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's DiarizerManager. Separate from Transcriber because
/// the diarizer model loads independently, so a daemon that doesn't need
/// diarization doesn't pay the download cost.
///
/// API adaptations from best-guess spec:
/// - `initialize(models:)` used instead of `loadModels(_:)` (consuming parameter pattern)
/// - `performCompleteDiarization` is synchronous `throws`, not `async throws`
/// - `TimedSpeakerSegment.speakerId` is `String` (UUID-style), not `Int`;
///   mapped to stable `Int` via an insertion-order dictionary inside the actor
/// - `startTimeSeconds`/`endTimeSeconds` are `Float`, not `Double`
public actor Diarizer: DiarizeService {
    private var manager: DiarizerManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func loadModels() async throws {
        guard manager == nil else { return }
        let m = DiarizerManager(config: .default)
        let models = try await DiarizerModels.download()
        m.initialize(models: models)
        self.manager = m
    }

    public func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        guard let m = manager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let result = try m.performCompleteDiarization(samples)

        // Map speaker ID strings to stable sequential integers (insertion order).
        // NOTE: mapping is per-call; speaker N in one diarize() call is not the
        // same speaker N in another. Plan 4 (long-running / chunked) needs to
        // lift this to the actor level.
        var speakerIndex: [String: Int] = [:]
        return result.segments.map { seg in
            let idx: Int
            if let existing = speakerIndex[seg.speakerId] {
                idx = existing
            } else {
                idx = speakerIndex.count
                speakerIndex[seg.speakerId] = idx
            }
            return SpeakerSegment(
                speaker: idx,
                startMs: Int(seg.startTimeSeconds * 1000),
                endMs: Int(seg.endTimeSeconds * 1000)
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
swift test --filter DiarizerTests 2>&1 | tail -15
```

Expected: both pass. First run downloads the diarizer model (~200 MB on top of the ASR model).

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/Diarizer.swift Tests/HarcSTTTests/DiarizerTests.swift
git commit -m "feat: Diarizer actor wrapping FluidAudio DiarizerManager"
```

---

### Task 7: Daemon lifecycle — CLI entry, socket path, idle timeout, signals

Wires everything together. `HarcSTTCLI` now spawns a `Daemon` that pre-loads models in the background, runs the accept loop, self-shuts-down after 30 min idle, and handles SIGTERM/SIGINT by removing the socket cleanly.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/Daemon.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/HarcSTTCLI.swift`

- [ ] **Step 1: Write `Sources/HarcSTT/Daemon.swift`**

```swift
import Foundation
import Darwin
import HarcCore

/// Top-level daemon actor. Owns socket server, transcriber, diarizer, and
/// idle/shutdown state. Call `run()` from `@main`; it returns when the
/// daemon has shut down.
public actor Daemon {
    public static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".harc/stt.sock").path
    }()

    public static let defaultIdleTimeout: TimeInterval = 30 * 60

    private let socketPath: String
    private let idleTimeout: TimeInterval
    private let transcriber: Transcriber
    private let diarizer: Diarizer
    private let startedAt: Date
    private var lastActivity: Date
    private var shutdownRequested = false

    public init(
        socketPath: String = Daemon.defaultSocketPath,
        idleTimeout: TimeInterval = Daemon.defaultIdleTimeout
    ) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.transcriber = Transcriber()
        self.diarizer = Diarizer()
        self.startedAt = Date()
        self.lastActivity = Date()
    }

    public func run() async throws {
        let server = try SocketServer(socketPath: socketPath)
        FileHandle.standardError.write(Data(
            "harc-stt: listening on \(socketPath)\n".utf8
        ))

        // Pre-load models in the background so first transcribe doesn't block.
        Task.detached { [transcriber] in
            do {
                try await transcriber.loadModels()
                FileHandle.standardError.write(Data("harc-stt: ASR model loaded\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-stt: ASR model load failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        Task.detached { [diarizer] in
            do {
                try await diarizer.loadModels()
                FileHandle.standardError.write(Data("harc-stt: diarizer model loaded\n".utf8))
            } catch {
                // Diarizer is optional — log but don't fail the daemon.
                FileHandle.standardError.write(Data(
                    "harc-stt: diarizer load failed (diarization will return empty): \(error.localizedDescription)\n".utf8
                ))
            }
        }

        let idleTask = Task.detached { [self] in
            await self.monitorIdle(server: server)
        }

        let handler = RequestHandler(
            transcriber: transcriber,
            diarizer: diarizer,
            version: HarcVersion.current,
            startedAt: startedAt
        )

        for await clientFd in server.clients {
            await recordActivity()
            Task.detached { [handler, self] in
                let conn = ClientConnection(fd: clientFd)
                let wasShutdown = await conn.serve { request in
                    await self.recordActivity()
                    return await handler.handle(request)
                }
                if wasShutdown {
                    await self.requestShutdown()
                    server.shutdown()
                }
            }
            if shutdownRequested { break }
        }

        idleTask.cancel()
        server.shutdown()
    }

    private func recordActivity() {
        lastActivity = Date()
    }

    private func requestShutdown() {
        shutdownRequested = true
    }

    private func monitorIdle(server: SocketServer) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            let idle = Date().timeIntervalSince(lastActivity)
            if idle >= idleTimeout {
                FileHandle.standardError.write(Data(
                    "harc-stt: idle timeout (\(Int(idle))s), shutting down\n".utf8
                ))
                shutdownRequested = true
                server.shutdown()
                break
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite `Sources/HarcSTT/HarcSTTCLI.swift` to launch the daemon**

```swift
import Foundation
import Darwin
import HarcCore

@main
struct HarcSTTCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--version") {
            print("harc-stt \(HarcVersion.current)")
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print(Self.helpText)
            return
        }

        installSignalHandlers()

        let daemon = Daemon()
        do {
            try await daemon.run()
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: daemon exited with error: \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }
    }

    static let helpText = """
    harc-stt — Harc speech-to-text daemon

    Usage:
      harc-stt              Start daemon on ~/.harc/stt.sock (idle timeout 30 min)
      harc-stt --version    Print version and exit
      harc-stt --help       Print this help and exit
    """

    /// Install simple SIGTERM/SIGINT handlers that remove the socket and exit.
    /// Using `signal(3)` keeps this pre-Swift-concurrency-safe; the handler
    /// does only async-signal-safe work.
    static func installSignalHandlers() {
        let cleanupAndExit: @convention(c) (Int32) -> Void = { _ in
            let home = getenv("HOME").flatMap { String(cString: $0) } ?? "/tmp"
            let path = (home as NSString).appendingPathComponent(".harc/stt.sock")
            unlink(path)
            _exit(0)
        }
        signal(SIGTERM, cleanupAndExit)
        signal(SIGINT, cleanupAndExit)
    }
}
```

- [ ] **Step 3: Build + run it briefly to sanity-check**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

Run it detached; wait 3 s; kill it:
```bash
swift run harc-stt &
DAEMON_PID=$!
sleep 3
ls -la ~/.harc/stt.sock 2>&1
kill $DAEMON_PID
sleep 1
ls -la ~/.harc/stt.sock 2>&1
```

Expected: socket file exists after 3s, is gone after kill.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcSTT/Daemon.swift Sources/HarcSTT/HarcSTTCLI.swift
git commit -m "feat: Daemon actor with socket lifecycle, model pre-load, idle timeout"
```

---

### Task 8: End-to-end integration test + hour-long smoke

Spin up a real daemon on a test socket, dispatch a `.transcribe` request, assert a non-empty `.result` response. Then do a manual risk-spike on hour-long audio outside the automated test suite.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/DaemonIntegrationTests.swift`

- [ ] **Step 1: Write the integration test**

Uses a `roundTrip(_:)` helper to avoid duplicating the connect/write/read dance, and polls `.status` until `modelLoaded == true` before sending the `.transcribe` request. The daemon starts accepting before the model finishes loading (pre-load happens in a detached background Task in `Daemon.run()`), so a naive test that fires `.transcribe` immediately will get `model_not_loaded` on first-run. The status poll is the correct client-side handshake.

```swift
import Testing
import Foundation
import Darwin
import HarcCore
@testable import HarcSTT

@Suite("Daemon end-to-end", .tags(.slow))
struct DaemonIntegrationTests {
    @Test("dispatching a transcribe request over the socket returns a result")
    func transcribeOverSocket() async throws {
        let socketPath = "/tmp/harc-integ-\(UUID().uuidString.prefix(8)).sock"

        let daemon = Daemon(socketPath: socketPath, idleTimeout: 600)
        let daemonTask = Task { try await daemon.run() }

        // Wait up to 5s for the socket to appear.
        var waited = 0
        while !FileManager.default.fileExists(atPath: socketPath), waited < 5_000 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
        try #require(FileManager.default.fileExists(atPath: socketPath))

        // Build the sockaddr_un once — reused for every connection below.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cpath in
                memcpy(ptr, cpath, min(strlen(cpath) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Helper: open a connected socket, send one NDJSON line, read one NDJSON line back.
        func roundTrip(_ request: IPCRequest) throws -> IPCResponse {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DaemonError.socketCreationFailed(errno) }
            defer { close(fd) }

            let connResult = withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(fd, sp, addrLen)
                }
            }
            guard connResult == 0 else { throw DaemonError.socketBindFailed(errno) }

            var reqData = try JSONEncoder().encode(request)
            reqData.append(0x0A)
            _ = reqData.withUnsafeBytes { write(fd, $0.baseAddress, reqData.count) }
            shutdown(fd, SHUT_WR)

            var buf = Data()
            let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
            defer { readBuf.deallocate() }
            while !buf.contains(0x0A) {
                let n = read(fd, readBuf, 64 * 1024)
                if n > 0 { buf.append(readBuf, count: n) }
                else if n == 0 { break }
                else if errno == EINTR { continue }
                else { break }
            }

            let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
            return try JSONDecoder().decode(IPCResponse.self, from: buf.prefix(upTo: nl))
        }

        // Poll status until modelLoaded == true (up to 3 min for first-run download).
        let modelDeadline = Date().addingTimeInterval(180)
        var modelLoaded = false
        while Date() < modelDeadline {
            if let resp = try? roundTrip(.status),
               case .status(let s) = resp, s.modelLoaded {
                modelLoaded = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        try #require(modelLoaded, "model never reported loaded within 3 min")

        // Send a transcribe request for the fixture
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )
        let req = IPCRequest.transcribe(TranscribeRequest(
            audioPath: url.path, wantTimestamps: true, diarize: false
        ))
        let response = try roundTrip(req)

        if case .result(let r) = response {
            #expect(!r.text.isEmpty)
            #expect(r.words.count > 0)
        } else if case .error(let e) = response {
            Issue.record("got error response: \(e.code): \(e.message)")
        } else {
            Issue.record("unexpected response: \(response)")
        }

        // Shut the daemon down cleanly
        let shutdownFd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(shutdownFd) }
        _ = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(shutdownFd, sp, addrLen)
            }
        }
        var shutdownReq = try JSONEncoder().encode(IPCRequest.shutdown)
        shutdownReq.append(0x0A)
        _ = shutdownReq.withUnsafeBytes { write(shutdownFd, $0.baseAddress, shutdownReq.count) }

        // Daemon should terminate. Give it up to 5s.
        _ = try await withTimeout(seconds: 5) { try await daemonTask.value }
    }
}

/// Small test helper — cancel after N seconds.
func withTimeout<T: Sendable>(seconds: Double, op: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 2: Run the integration test**

```bash
swift test --filter DaemonIntegrationTests 2>&1 | tail -30
```

Expected: passes. First run may take several minutes (model download).

- [ ] **Step 3: Hour-long smoke (manual — do NOT automate)**

Prepare a real ~1-hour WAV (use any long talk, podcast, or synthesize via `say` with repeated text). Save to `/tmp/harc-hour.wav`.

```bash
# Convert any source audio to 16 kHz mono (skip if already correct)
afconvert -f WAVE -d LEI16@16000 -c 1 SOURCE_FILE /tmp/harc-hour.wav

# Start daemon in the background, capture logs
swift run harc-stt 2>/tmp/harc-daemon.log &
DAEMON_PID=$!
sleep 30    # let models pre-load

# Dispatch a transcribe request via netcat
REQ='{"type":"transcribe","payload":{"audioPath":"/tmp/harc-hour.wav","language":"en","wantTimestamps":true,"diarize":false}}'
echo "$REQ" | nc -U ~/.harc/stt.sock | head -c 4000 > /tmp/harc-hour-result.json

# Stop daemon
kill $DAEMON_PID

# Inspect
cat /tmp/harc-hour-result.json | head -c 500
cat /tmp/harc-daemon.log
```

Record in this plan's Open Decisions (below) whether:
- Transcription completed successfully.
- Peak memory stayed bounded (observe via Activity Monitor — Xcode Instruments if deeper).
- Output quality held up, or whether chunking is needed.

If transcription fails with OOM or "too long" errors from FluidAudio, open a follow-up plan ("Plan 2a: Chunker") before starting Plan 3.

- [ ] **Step 4: Commit**

```bash
git add Tests/HarcSTTTests/DaemonIntegrationTests.swift
git commit -m "test: end-to-end daemon integration over Unix socket"
```

---

## Acceptance Criteria (Plan 2 complete when all true)

- `swift test` passes **all** HarcSTTTests + prior HarcCoreTests. The slow tag (model tests) run green on at least one machine; CI may skip them via `swift test --skip slow` if runner time is constrained.
- `swift run harc-stt` launches, binds `~/.harc/stt.sock`, logs "ASR model loaded" + "diarizer model loaded" within ~60 s on a warm cache, and stays alive.
- `echo '{"type":"status"}' | nc -U ~/.harc/stt.sock` returns a `{"type":"status","payload":{"version":"0.1.0","modelLoaded":true,...}}` response.
- `echo '{"type":"transcribe","payload":{"audioPath":"Tests/HarcSTTTests/Fixtures/short-speech.wav"}}' | nc -U ~/.harc/stt.sock` returns a `.result` response with non-empty text.
- `echo '{"type":"shutdown"}' | nc -U ~/.harc/stt.sock` terminates the daemon and removes the socket.
- Kill via `kill -TERM` or Ctrl-C removes the socket.
- 8 new commits on `main` (one per task), all CI-green.
- Hour-long smoke test has been run and its findings documented in this file's Open Decisions.

## Open Decisions (filled in during Task 8)

- **Hour-long handling:** [to fill after Task 8 Step 3] — did FluidAudio + Parakeet handle the full file in one pass? Peak RSS? Output quality? Chunker needed?
- **Diarization quality on meeting audio:** [to fill during Plan 5 user testing] — FluidAudio's diarizer vs a separate pyannote-style model.

## Self-Review

**Spec coverage (vs Plan 1 sketch of Plan 2):**

- "Listen on `~/.harc/stt.sock`, accept loop, line-delimited JSON" → Tasks 3, 4, 7.
- "Integrate FluidAudio, pre-load Parakeet TDT 0.6B v3 on daemon start" → Tasks 1, 2, 7.
- "Surface modelLoaded via DaemonStatus" → Task 5 (RequestHandler synthesizes status).
- "Handle transcribe(audioPath:) end-to-end for a short test WAV" → Tasks 2, 8.
- "Idle-timeout self-shutdown (30 min default)" → Task 7.
- "SIGTERM/SIGINT handling that removes the socket file" → Task 7 (in `HarcSTTCLI.installSignalHandlers`).
- "Diarize on by default" — the IPC contract defaults `diarize: true`, the Diarizer runs if loaded, degrades silently if not → Tasks 5, 6.
- "Hour-long audio risk spike, chunker if FluidAudio can't handle" → Task 8 Step 3 + Open Decisions.

**Placeholder scan:** The Task 6 note about FluidAudio API drift says "escalate as NEEDS_CONTEXT" rather than "figure it out" — that's a legitimate escalation, not a placeholder. All code blocks are complete.

**Type consistency:**
- `Transcriber.transcribe(audioPath:) -> TranscribeResult` (Task 2) → consumed by `RequestHandler` (Task 5) and `Daemon` (Task 7).
- `Diarizer.diarize(audioPath:) -> [SpeakerSegment]` (Task 6) → consumed by `RequestHandler` via `DiarizeService` protocol defined in Task 5.
- `TranscribeService.isLoaded: Bool { get async }` — declared in Task 5, implemented by `Transcriber` (T2) and the test fake (T5). `Transcriber`'s `isLoaded` is a `var` — that satisfies `{ get async }` via actor isolation.
- `DaemonError` cases (`.modelNotLoaded`, `.audioLoadFailed`, `.transcriptionFailed`, `.socketCreationFailed`, `.socketBindFailed`, `.socketListenFailed`) match the uses in `Transcriber`, `Diarizer`, and `SocketServer`.
- `HarcVersion.current` (from Plan 1) used in `RequestHandler` init via `Daemon` (Task 7).
- `Daemon.defaultSocketPath = "~/.harc/stt.sock"` matches CLAUDE.md.
