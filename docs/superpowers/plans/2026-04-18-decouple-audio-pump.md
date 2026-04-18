# Decouple mic + system-audio pump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `RecordingSession`'s pump-stream deadlock — mic and system-audio streams pair 1:1 synchronously, so a slow or cadence-mismatched sys stream starves the mic side after one buffer. Replace with a latest-value pattern: sys drains into a shared slot, mic pump reads current sys (or nil) on each tick.

**Architecture:** Add a `LatestSystemBuffer` actor as a single-slot mailbox. Spawn a dedicated task to drain the sys stream into the slot (overwriting on each new buffer). The mic pump reads `take()` — which consumes the slot — on each mic tick, passing nil to `processPair` when sys hasn't produced new audio. Preserves existing mixer / writer / transcriber wiring.

**Tech Stack:** Swift 6 strict concurrency, `@preconcurrency import AVFAudio`, Swift Testing (`@Test`, `#expect`).

---

### Task 1: Reproducing test for the deadlock

Add a test that drives a mic stream at 10 buffers then finishes, while the sys stream emits 1 buffer and then HANGS FOREVER (never finishes, never emits more). The current pump will write exactly 1 mix and deadlock at `sysIter.next()` on iteration 2. After the fix, the pump should write all 10 mics (with sys mixed into the first, mic-only for the rest) and complete cleanly.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTests.swift`

- [ ] **Step 1: Add a `FakeSystemHanging` actor at the bottom of the `RecordingSessionTests` struct's fakes block**

Place this after the existing `FakeSystem` actor (around line 56):

```swift
    /// System-audio fake that emits N buffers then HANGS — stream never finishes,
    /// never emits more. Models real ScreenCaptureKit when mic/sys cadences differ.
    actor FakeSystemHanging: SystemAudioCaptureSource {
        nonisolated let script: [AVAudioPCMBuffer]
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(script: [AVAudioPCMBuffer]) { self.script = script }
        func requestPermission() async throws {}
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached {
                for buf in box.buffers { cont.yield(buf) }
                // DELIBERATELY do not call cont.finish() — simulates a live
                // sys stream that is slower than mic and hasn't delivered more yet.
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }
```

- [ ] **Step 2: Add the failing test as the last @Test in the suite**

```swift
    @Test("mic pump survives a system stream that delivers fewer buffers than mic and doesn't finish")
    func micPumpSurvivesSlowSystemStream() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // 10 mic buffers, 1 sys buffer that stalls forever afterwards.
        let micBuffers = (0..<10).map { _ in makeConstantBuffer(0.1, frames: 1600) }
        let sysBuffers = [makeConstantBuffer(0.2, frames: 1600)]

        let mic = FakeMic(script: micBuffers)
        let sys = FakeSystemHanging(script: sysBuffers)
        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: RecordingDestination(baseDirectory: base),
            transcriber: nil
        )

        try await session.start(at: Date())
        // Give the pump enough time to drain the 10-buffer mic stream.
        // If the pump deadlocks on sysIter.next(), this test will TIME OUT.
        try await Task.sleep(for: .milliseconds(500))
        let result = try await session.stop()

        // Verify the WAV has > 1 buffer's worth of frames.
        // 10 buffers × 1600 frames = 16000 frames = 1.0s at 16kHz.
        // If the deadlock bug is present, the file will have ~1600 frames (0.1s).
        let af = try AVAudioFile(forReading: result.wavURL)
        #expect(af.length > 5000, "expected >5000 frames; got \(af.length) (pump deadlocked?)")
    }
```

- [ ] **Step 3: Run — expect timeout or deadlock-reveal**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingSessionTests.micPumpSurvivesSlowSystemStream 2>&1 | tail -20
```

Expected: test FAILS. Either a timeout, or the assertion fires because `af.length` ≈ 1600 (single mic buffer written before the pump deadlocked). Either outcome proves the bug.

If the test times out, set a reasonable swift-test timeout or the test harness's default so CI doesn't hang. Swift Testing does not honor a wall-clock timeout by default, so the `Task.sleep` + explicit `stop()` is the gate — the pump should drain within 500ms of mic-buffer delivery. If the deadlock bug is active, `stop()` itself may hang waiting for `pumpTask`. Add a `Task.sleep(for: .seconds(2))` race if needed — but prefer letting the test hang so the fix is visibly required.

---

### Task 2: Rewrite the pump with a latest-value sys slot

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/RecordingSession.swift`

- [ ] **Step 1: Add a `LatestSystemBuffer` actor at the bottom of the file** (after `pumpStreams` function)

```swift
/// Single-slot mailbox for the most recent system-audio buffer.
/// The sys-drain task overwrites the slot; the mic pump consumes it on each tick.
/// `take()` returns nil if no new sys buffer has arrived since the last read —
/// the pump treats that as "mic-only for this tick."
private actor LatestSystemBuffer {
    private var current: AVAudioPCMBuffer?

    func put(_ buffer: AVAudioPCMBuffer) {
        current = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        let b = current
        current = nil
        return b
    }
}
```

- [ ] **Step 2: Replace the `pumpStreams` free function**

Current (buggy) body:
```swift
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

Replace with:
```swift
private func pumpStreams(
    session: RecordingSession,
    mic micStream: AsyncStream<AVAudioPCMBuffer>,
    system sysStream: AsyncStream<AVAudioPCMBuffer>?
) async {
    guard let sysStream else {
        for await micBuffer in micStream {
            session.processPair(mic: micBuffer, system: nil)
        }
        return
    }

    let latest = LatestSystemBuffer()

    // Drain the sys stream into the latest-slot. Consumes every sys buffer
    // so the writer can't stall; the mic pump picks whichever arrived most
    // recently on each mic tick. Cancellation-safe.
    let sysTask = Task { [latest] in
        for await buf in sysStream {
            await latest.put(buf)
        }
    }

    // Mic drives the mix cadence. Each mic buffer reads the latest sys buffer
    // (or nil if none has arrived since last read) and mixes accordingly.
    for await micBuffer in micStream {
        let sysBuffer = await latest.take()
        session.processPair(mic: micBuffer, system: sysBuffer)
    }

    sysTask.cancel()
    _ = await sysTask.value
}
```

- [ ] **Step 3: Verify the reproducing test now passes**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingSessionTests.micPumpSurvivesSlowSystemStream 2>&1 | tail -10
```

Expected: PASS. `af.length > 5000` (should be ~16000 frames, i.e., all 10 mic buffers × 1600 frames each — possibly slightly different due to mixer's resample math, but definitively > 5000).

- [ ] **Step 4: Run the full HarcAudioTests suite**

```bash
swift test --filter HarcAudioTests 2>&1 | tail -15
```

Expected: all existing tests still pass. The refactor does not change the 1:1 mic-drives-mix contract; existing tests using `FakeSystem` (which finishes its stream) still behave identically because `sysTask` will complete naturally when its input finishes.

- [ ] **Step 5: Run the full test suite + strict-concurrency build**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
swift test 2>&1 | tail -10
```

Expected: clean build. 66 tests / 25 suites pass (1 new test added). No new concurrency warnings.

---

### Task 3: Build + commit

- [ ] **Step 1: Regenerate xcodeproj + verify app builds**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Commit**

```bash
git add Sources/HarcAudio/RecordingSession.swift Tests/HarcAudioTests/RecordingSessionTests.swift
git commit -m "fix: decouple mic + system-audio pump with latest-value slot"
```

---

## Acceptance Criteria

- New test `micPumpSurvivesSlowSystemStream` passes.
- All prior HarcAudioTests still pass.
- `swift build -Xswiftc -strict-concurrency=complete` clean.
- `xcodebuild` succeeds.
- After the fix, recording for 10s in the running app produces a WAV > 1MB (not 7KB).
