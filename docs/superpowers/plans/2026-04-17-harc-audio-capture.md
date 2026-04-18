# Harc Audio Capture Implementation Plan (Plan 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture microphone + system audio during a recording session, mix them into 16 kHz mono Float32, write a durable WAV while recording, and atomically move the file into the user's destination folder on stop — with graceful degradation to mic-only if screen-recording permission is unavailable.

**Architecture:** A new SwiftPM library `HarcAudio` that the `Harc` app links against. `RecordingSession` is the top-level actor. It owns two capture sources (`MicCapture` via `AVAudioEngine`, `SystemAudioCapture` via `ScreenCaptureKit`), an `AudioMixer` that resamples both to 16 kHz mono + sums them, and an `AudioFileWriter` that streams samples to `~/Library/Caches/Harc/recordings/<uuid>.wav` with periodic `fsync`. On stop, `RecordingDestination` produces the public-facing path (`<dest>/YYYY/YYYY-MM-DD/HH-mm-ss.wav`) and performs an atomic rename. `MicCapture` and `SystemAudioCapture` sit behind narrow protocols so `RecordingSession` can be tested against synthetic audio sources without touching real hardware.

**Tech Stack:** Swift 6.0, SwiftPM, Swift Testing, AVFoundation (`AVAudioEngine`, `AVAudioFile`, `AVAudioConverter`), ScreenCaptureKit (`SCStream`, `SCShareableContent`, `SCContentFilter`), Accelerate (for the occasional DSP op), Darwin (`fsync`). macOS 14+, Apple Silicon.

---

## Prerequisites

- Plan 1 and Plan 2 complete on `main`. Latest commit `868dadf test: end-to-end daemon integration over Unix socket`. `swift test` passes 22 tests in 9 suites.
- Info.plist already declares `NSMicrophoneUsageDescription` + `NSScreenCaptureUsageDescription` (wired in Plan 1 Task 5).
- Entitlements already include `com.apple.security.device.audio-input` (Plan 1 Task 6). Screen recording is TCC-prompted at runtime; no entitlement needed.
- Running the app to exercise the new menu item will trigger first-run TCC prompts for Microphone and Screen Recording. Grant both in System Settings → Privacy & Security.

## Scope Boundary

This plan produces **recording of a real meeting to a durable WAV with atomic destination move**. Out of scope:

- Rolling 60-second chunked transcription during recording (Plan 4).
- Menu bar popover UI (Plan 5) — Plan 3 adds a minimal "Start/Stop Recording" menu item for manual exercise.
- Clipboard history / library (Plan 6).
- User-configurable destination folder (Plan 5 adds the Settings UI; Plan 3 hardcodes the default `~/Documents/Harc/`).
- Global hotkey (Plan 5).
- VAD / silence gating (CLAUDE.md open decision, potential Plan 3a).
- Meeting-name slug in filename (CLAUDE.md open decision, potential Plan 5 settings).

## File Structure

After Plan 3:

```
Harc/
├── Package.swift                                  (modified — +HarcAudio product + test target)
├── project.yml                                    (modified — +HarcAudio dep on Harc target)
├── Sources/
│   ├── HarcAudio/                                 (new library target)
│   │   ├── RecordingDestination.swift             T2
│   │   ├── AudioFileWriter.swift                  T3
│   │   ├── AudioMixer.swift                       T4
│   │   ├── MicCapture.swift                       T5
│   │   ├── SystemAudioCapture.swift               T6
│   │   ├── RecordingSession.swift                 T7
│   │   └── AudioError.swift                       T2
│   ├── HarcCore/                                  (unchanged)
│   └── HarcSTT/                                   (unchanged)
├── Tests/
│   └── HarcAudioTests/                            (new test target)
│       ├── RecordingDestinationTests.swift        T2
│       ├── AudioFileWriterTests.swift             T3
│       ├── AudioMixerTests.swift                  T4
│       └── RecordingSessionTests.swift            T7
└── HarcApp/
    └── AppDelegate.swift                          (modified — +Start/Stop menu items)  T8
```

### Responsibilities

- **`RecordingDestination`** — pure path logic. Given a base directory + a `Date`, returns the target `.wav` path under `YYYY/YYYY-MM-DD/HH-mm-ss.wav`. Collision handling: append `-1`, `-2`, … if the file exists. Also provides the cache-directory scratch path where recording writes live until stop. Exposes `atomicMove(from:to:) throws` wrapping `FileManager.replaceItem`.
- **`AudioError`** — typed errors: `.micPermissionDenied`, `.systemAudioPermissionDenied`, `.audioEngineFailed(String)`, `.fileWriteFailed(String)`, `.conversionFailed(String)`.
- **`AudioFileWriter`** — wraps `AVAudioFile` opened for writing at 16 kHz mono Int16 PCM. `write(_ buffer: AVAudioPCMBuffer) throws`, `fsyncIfDue()` throws (checks a timer, fsyncs the underlying file fd every 5 seconds), `close() throws`. Safe single-owner (not Sendable-by-default; caller is responsible for single-threaded use via an actor).
- **`AudioMixer`** — takes two independent audio streams (mic at ~48 kHz stereo Float32 from AVAudioEngine, system at 48 kHz stereo Float32 from ScreenCaptureKit), resamples both to 16 kHz mono Float32, sums them sample-aligned, emits a single `AVAudioPCMBuffer` stream. Uses `AVAudioConverter` for each input. Internal state is per-mixer instance (two `AVAudioConverter`s + ring buffers); not designed for shared access.
- **`MicCapture`** — `MicCaptureSource` protocol + `RealMicCapture` concrete impl. Wraps `AVAudioEngine`, installs a tap on `inputNode`, exposes `start() async throws -> AsyncStream<AVAudioPCMBuffer>` + `stop() async`. Permission check via `AVCaptureDevice.requestAccess(for: .audio)`.
- **`SystemAudioCapture`** — `SystemAudioCaptureSource` protocol + `RealSystemAudioCapture` concrete impl. Wraps `SCStream` in audio-only mode, exposes the same `start()` / `stop()` shape. First call to `SCShareableContent.current` triggers the TCC prompt on first run.
- **`RecordingSession`** — actor. `start(destination:)` kicks off mic + optional system audio, plumbs both into the mixer, drives the writer. `stop() -> URL` stops captures, closes the writer, atomically moves the file, returns the final URL. Handles the graceful-degradation branch (mic-only if system permission denied). Not a singleton — one instance per recording.

### Why split this way

Each piece is independently testable:
- **`RecordingDestination`**: pure path/date computation. 100% synthetic inputs.
- **`AudioFileWriter`**: synthetic `AVAudioPCMBuffer` input → real WAV output verified via `AVAudioFile` readback.
- **`AudioMixer`**: synthetic sine-wave + square-wave inputs at different rates → verify output rate, channel count, sample count, and summed amplitude.
- **`RecordingSession`**: inject `FakeMicCapture` + `FakeSystemAudioCapture` (both `AsyncStream`-driven) into the session; assert the resulting WAV contents.

`MicCapture` and `SystemAudioCapture` are deliberately thin wiring around OS APIs — most logic lives in the testable pieces above them.

## Testing Notes

- Tests that open `AVAudioFile`s use a temp directory under `/tmp/harc-audio-test-<uuid>/`. Cleaned up in a `defer` per test.
- Buffer fixtures are synthetic: sine wave generators at known frequencies, so tests can spot-check signal energy without parsing ASR output.
- No real mic or screen-recording tests in automation. Manual smoke via Task 8's menu item is the only verification of the real capture paths.
- Tests run under Swift 6 strict concurrency. All shared state is actor-isolated or explicitly Sendable.

---

### Task 1: `HarcAudio` SwiftPM target scaffolding

Adds a new library target + test target. Minimal placeholder type to verify everything wires up.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Modify: `/Users/jlane/GitHub/Harc/project.yml`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/AudioError.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/ScaffoldTests.swift`

- [ ] **Step 1: Rewrite `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcAudio", targets: ["HarcAudio"]),
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
        .testTarget(
            name: "HarcAudioTests",
            dependencies: [
                "HarcAudio",
                "HarcCore",
            ]
        ),
    ]
)
```

- [ ] **Step 2: Modify `project.yml`** — add `HarcAudio` as a second product under the `HarcCore` package entry

In the `packages:` block, the entry already reads:
```yaml
packages:
  HarcCore:
    path: .
```
Leave that alone. In the `targets.Harc.dependencies:` block, the existing entry is:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
```
Change it to:
```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
```
(The package name "HarcCore" is the xcodegen-local alias for the SwiftPM package at `.`, not a product name. It stays the same; we just declare an additional product dependency.)

- [ ] **Step 3: Write `Sources/HarcAudio/AudioError.swift`**

```swift
import Foundation

public enum AudioError: Error, LocalizedError, Equatable {
    case micPermissionDenied
    case systemAudioPermissionDenied
    case audioEngineFailed(String)
    case systemAudioStreamFailed(String)
    case fileWriteFailed(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone access denied. Grant permission in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermissionDenied:
            return "Screen recording access denied. Grant permission in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .audioEngineFailed(let reason):
            return "Audio engine failure: \(reason)"
        case .systemAudioStreamFailed(let reason):
            return "System audio capture failed: \(reason)"
        case .fileWriteFailed(let reason):
            return "Audio file write failed: \(reason)"
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        }
    }
}
```

- [ ] **Step 4: Write `Tests/HarcAudioTests/ScaffoldTests.swift`**

```swift
import Testing
@testable import HarcAudio

@Suite("HarcAudio scaffold")
struct ScaffoldTests {
    @Test("AudioError cases have non-empty descriptions")
    func errorDescriptions() {
        let errs: [AudioError] = [
            .micPermissionDenied,
            .systemAudioPermissionDenied,
            .audioEngineFailed("x"),
            .systemAudioStreamFailed("y"),
            .fileWriteFailed("z"),
            .conversionFailed("w"),
        ]
        for err in errs {
            #expect(err.errorDescription?.isEmpty == false, "empty description for \(err)")
        }
    }
}
```

- [ ] **Step 5: Build and test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
```

Expected: `Build complete!` and 23 tests in 10 suites passing (22 prior + 1 new).

- [ ] **Step 6: Regenerate Xcode project and verify app still builds**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The Xcode target now links `HarcAudio` alongside `HarcCore`, though no app code imports it yet.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved project.yml Sources/HarcAudio Tests/HarcAudioTests
git commit -m "build: add HarcAudio library target with AudioError scaffold"
```

---

### Task 2: `RecordingDestination` — path generator + atomic move

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/RecordingDestination.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingDestinationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import HarcAudio

@Suite("RecordingDestination")
struct RecordingDestinationTests {
    private func makeTempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-dest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("publicPath yields YYYY/YYYY-MM-DD/HH-mm-ss.wav under base")
    func publicPathShape() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // 2026-04-17T13:14:15 local time
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 13; comps.minute = 14; comps.second = 15
        comps.timeZone = TimeZone.current
        let date = Calendar.current.date(from: comps)!

        let dest = RecordingDestination(baseDirectory: base)
        let url = try dest.publicPath(for: date)
        let components = url.pathComponents
        #expect(components.contains("2026"))
        #expect(components.contains("2026-04-17"))
        #expect(url.lastPathComponent == "13-14-15.wav")
        #expect(url.path.hasPrefix(base.path))
    }

    @Test("publicPath appends -1, -2 on collision")
    func publicPathCollisionSuffix() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let date = Date()
        let dest = RecordingDestination(baseDirectory: base)

        let first = try dest.publicPath(for: date)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: first.path, contents: Data([0x00]))

        let second = try dest.publicPath(for: date)
        #expect(second.lastPathComponent.hasSuffix("-1.wav"))
        FileManager.default.createFile(atPath: second.path, contents: Data([0x00]))

        let third = try dest.publicPath(for: date)
        #expect(third.lastPathComponent.hasSuffix("-2.wav"))
    }

    @Test("cachePath is under ~/Library/Caches/Harc/recordings and ends with .wav")
    func cachePathShape() {
        let cache = RecordingDestination.cachePath()
        #expect(cache.pathExtension == "wav")
        #expect(cache.path.contains("/Library/Caches/Harc/recordings/"))
    }

    @Test("atomicMove relocates a file and removes the source")
    func atomicMoveRelocates() throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let src = base.appendingPathComponent("src.wav")
        let dst = base.appendingPathComponent("a/b/dst.wav")
        FileManager.default.createFile(atPath: src.path, contents: Data([1, 2, 3]))

        try RecordingDestination.atomicMove(from: src, to: dst)

        #expect(FileManager.default.fileExists(atPath: dst.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let data = try Data(contentsOf: dst)
        #expect(data == Data([1, 2, 3]))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingDestinationTests 2>&1 | tail -15
```

Expected: compile errors — `RecordingDestination` doesn't exist.

- [ ] **Step 3: Write `Sources/HarcAudio/RecordingDestination.swift`**

```swift
import Foundation

public struct RecordingDestination: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Default base: `~/Documents/Harc/`. Plan 5 will replace this with user-configurable.
    public static func defaultBaseDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/Harc", isDirectory: true)
    }

    /// The in-progress cache path for a recording, e.g. `~/Library/Caches/Harc/recordings/<uuid>.wav`.
    /// Fresh UUID every call — callers keep the URL for the duration of one recording.
    public static func cachePath() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Harc/recordings", isDirectory: true)
        return dir.appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// The final public path for a recording started at `date`.
    /// Shape: `<base>/YYYY/YYYY-MM-DD/HH-mm-ss.wav`. Appends `-1`, `-2`, … on collision.
    public func publicPath(for date: Date) throws -> URL {
        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: date))
        let month = String(format: "%02d", cal.component(.month, from: date))
        let day = String(format: "%02d", cal.component(.day, from: date))
        let hour = String(format: "%02d", cal.component(.hour, from: date))
        let minute = String(format: "%02d", cal.component(.minute, from: date))
        let second = String(format: "%02d", cal.component(.second, from: date))

        let dayDir = baseDirectory
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day)", isDirectory: true)
        let base = "\(hour)-\(minute)-\(second)"

        var candidate = dayDir.appendingPathComponent("\(base).wav")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dayDir.appendingPathComponent("\(base)-\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// Move a finished recording into the destination hierarchy, creating parent directories.
    /// Uses `replaceItem` for atomicity across the rename + potential overwrite.
    public static func atomicMove(from src: URL, to dst: URL) throws {
        let parent = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // replaceItem handles both pre-existing dst and fresh dst.
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: src)
        } else {
            try FileManager.default.moveItem(at: src, to: dst)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingDestinationTests 2>&1 | tail -15
```

Expected: all 4 tests pass.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 27 tests in 11 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcAudio/RecordingDestination.swift Tests/HarcAudioTests/RecordingDestinationTests.swift
git commit -m "feat: RecordingDestination path generator with date layout + atomic move"
```

---

### Task 3: `AudioFileWriter` — 16 kHz mono WAV streaming

Opens a WAV file for writing at 16 kHz mono 16-bit PCM (the native rate for Parakeet TDT v3). Accepts `AVAudioPCMBuffer` appends; periodic `fsync` every 5 seconds for crash durability.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/AudioFileWriter.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/AudioFileWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import AVFoundation
@testable import HarcAudio

@Suite("AudioFileWriter")
struct AudioFileWriterTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-wavwrite-\(UUID().uuidString.prefix(8)).wav")
    }

    /// Make a 16 kHz mono Float32 buffer filled with a sine wave at 440 Hz.
    private func makeSineBuffer(frames: AVAudioFrameCount, sampleRate: Double = 16000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / sampleRate))
        }
        return buf
    }

    @Test("writer produces a valid 16 kHz mono Int16 WAV with correct frame count")
    func producesValidWAV() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        try writer.write(makeSineBuffer(frames: 16000)) // 1 second of sine
        try writer.write(makeSineBuffer(frames: 16000)) // 1 more second
        try writer.close()

        let readback = try AVAudioFile(forReading: url)
        let processingFormat = readback.processingFormat
        #expect(readback.fileFormat.sampleRate == 16000)
        #expect(readback.fileFormat.channelCount == 1)
        #expect(readback.length == 32000, "expected 32000 frames, got \(readback.length)")
        _ = processingFormat
        // Confirm the on-disk format is Int16 PCM by walking RIFF chunks to find 'fmt '.
        // AVAudioFile may insert a JUNK pad chunk before 'fmt ', so we can't assume offset 34.
        let data = try Data(contentsOf: url)
        var chunkOffset = 12
        var bps: UInt16 = 0
        while chunkOffset + 8 <= data.count {
            let id = String(bytes: data[chunkOffset..<(chunkOffset + 4)], encoding: .ascii) ?? ""
            let size = Int(UInt32(data[chunkOffset + 4]) | (UInt32(data[chunkOffset + 5]) << 8)
                        | (UInt32(data[chunkOffset + 6]) << 16) | (UInt32(data[chunkOffset + 7]) << 24))
            if id == "fmt " && chunkOffset + 8 + 16 <= data.count {
                // bits-per-sample is at byte 14 within the fmt chunk data (offset 22 from chunk start).
                bps = UInt16(data[chunkOffset + 22]) | (UInt16(data[chunkOffset + 23]) << 8)
                break
            }
            chunkOffset += 8 + size + (size % 2) // word-align
        }
        #expect(bps == 16, "expected 16-bit, got \(bps)")
    }

    @Test("writer.close is idempotent — second close does not throw")
    func closeIsIdempotent() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        try writer.write(makeSineBuffer(frames: 1600))
        try writer.close()
        // Should not throw on second close.
        try writer.close()
    }

    @Test("writer rejects buffers whose sample rate or channel count disagrees with the file")
    func rejectsMismatch() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        let mismatched = makeSineBuffer(frames: 1600, sampleRate: 48000)
        #expect(throws: AudioError.self) {
            try writer.write(mismatched)
        }
        try writer.close()
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter AudioFileWriterTests 2>&1 | tail -15
```

Expected: `AudioFileWriter` not found.

- [ ] **Step 3: Write `Sources/HarcAudio/AudioFileWriter.swift`**

```swift
import Foundation
import AVFoundation
import Darwin

/// Writes 16 kHz mono Int16 PCM WAV incrementally. Caller must serialize
/// `write(_:)` and `close()`; not safe for concurrent use. Call `close()`
/// when done (idempotent).
public final class AudioFileWriter {
    public static let targetSampleRate: Double = 16000
    public static let targetChannels: AVAudioChannelCount = 1

    private let url: URL
    private var file: AVAudioFile?
    private var lastFsync = Date()
    private let fsyncInterval: TimeInterval = 5.0

    public init(url: URL) throws {
        self.url = url

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFileWriter.targetSampleRate,
            AVNumberOfChannelsKey: AudioFileWriter.targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw AudioError.fileWriteFailed("open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Append a buffer. The buffer's format must match the writer's target
    /// (16 kHz, 1 channel). If it doesn't, the call throws; callers (e.g.
    /// AudioMixer) are responsible for converting first.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        guard buffer.format.sampleRate == AudioFileWriter.targetSampleRate,
              buffer.format.channelCount == AudioFileWriter.targetChannels
        else {
            throw AudioError.conversionFailed(
                "expected \(Int(AudioFileWriter.targetSampleRate))Hz / \(AudioFileWriter.targetChannels)ch, " +
                "got \(Int(buffer.format.sampleRate))Hz / \(buffer.format.channelCount)ch"
            )
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioError.fileWriteFailed("write: \(error.localizedDescription)")
        }
        try fsyncIfDue()
    }

    /// Force an fsync if the interval has elapsed. Exposed for tests; normally
    /// called transparently by `write(_:)`.
    public func fsyncIfDue() throws {
        guard Date().timeIntervalSince(lastFsync) >= fsyncInterval else { return }
        try fsyncFileAtURL()
        lastFsync = Date()
    }

    public func close() throws {
        guard file != nil else { return }
        // Dropping the reference triggers the AVAudioFile writer's finalization.
        self.file = nil
        // Final fsync to flush the RIFF header update.
        try? fsyncFileAtURL()
    }

    private func fsyncFileAtURL() throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else {
            throw AudioError.fileWriteFailed("open for fsync failed: errno \(errno)")
        }
        defer { Darwin.close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw AudioError.fileWriteFailed("fsync failed: errno \(errno)")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter AudioFileWriterTests 2>&1 | tail -15
```

Expected: all 3 tests pass.

If the "rejectsMismatch" test fails because `AVAudioFile.write(from:)` tolerates format mismatches and resamples internally, our explicit guard still catches it first — the throw comes from our format check, not AVAudioFile. Confirm that path hits.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcAudio/AudioFileWriter.swift Tests/HarcAudioTests/AudioFileWriterTests.swift
git commit -m "feat: AudioFileWriter streaming 16 kHz mono Int16 WAV with periodic fsync"
```

---

### Task 4: `AudioMixer` — resample + sum mic and system audio

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/AudioMixer.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/AudioMixerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import AVFoundation
@testable import HarcAudio

@Suite("AudioMixer")
struct AudioMixerTests {
    private func makeFormat(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    private func makeConstantBuffer(
        value: Float,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buf
    }

    @Test("mixer resamples 48 kHz stereo mic buffer to 16 kHz mono with ~constant amplitude")
    func resamplesMicBuffer() throws {
        let mixer = AudioMixer()
        let inputFormat = makeFormat(rate: 48000, channels: 2)
        let input = makeConstantBuffer(value: 0.5, frames: 48000, format: inputFormat)

        let out = try mixer.processMic(input)
        #expect(out.format.sampleRate == 16000)
        #expect(out.format.channelCount == 1)
        #expect(out.frameLength == 16000, "expected ~16000 frames, got \(out.frameLength)")

        // Mono-sum of a stereo 0.5-constant is ~0.5 (per-channel average).
        // Resampling preserves amplitude for constants.
        let first = out.floatChannelData![0][0]
        #expect(abs(first - 0.5) < 0.05, "expected ~0.5, got \(first)")
    }

    @Test("mixer sums mic and system tracks sample-aligned when fed equal-length buffers")
    func sumsMicAndSystem() throws {
        let mixer = AudioMixer()
        let micIn = makeFormat(rate: 16000, channels: 1)
        let sysIn = makeFormat(rate: 16000, channels: 1)

        let mic = makeConstantBuffer(value: 0.2, frames: 1600, format: micIn)
        let sys = makeConstantBuffer(value: 0.3, frames: 1600, format: sysIn)

        let micOut = try mixer.processMic(mic)
        let sysOut = try mixer.processSystem(sys)
        let summed = try mixer.sum(mic: micOut, system: sysOut)

        #expect(summed.format.sampleRate == 16000)
        #expect(summed.format.channelCount == 1)
        #expect(summed.frameLength == 1600)
        let first = summed.floatChannelData![0][0]
        #expect(abs(first - 0.5) < 0.01, "expected 0.2 + 0.3 = 0.5, got \(first)")
    }

    @Test("mixer clamps summed output to [-1, 1] to prevent clipping overflow")
    func clampsToUnitRange() throws {
        let mixer = AudioMixer()
        let fmt = makeFormat(rate: 16000, channels: 1)

        // Two hot signals that would sum to 1.6 without clamping.
        let a = makeConstantBuffer(value: 0.8, frames: 800, format: fmt)
        let b = makeConstantBuffer(value: 0.8, frames: 800, format: fmt)

        let summed = try mixer.sum(mic: a, system: b)
        let first = summed.floatChannelData![0][0]
        #expect(first <= 1.0, "expected clamp to 1.0, got \(first)")
        #expect(first >= 1.0 - 0.01, "expected exactly 1.0 after clamp, got \(first)")
    }

    @Test("processSystem converts 48 kHz stereo to 16 kHz mono")
    func processesSystemBuffer() throws {
        let mixer = AudioMixer()
        let input = makeConstantBuffer(
            value: 0.3,
            frames: 48000,
            format: makeFormat(rate: 48000, channels: 2)
        )
        let out = try mixer.processSystem(input)
        #expect(out.format.sampleRate == 16000)
        #expect(out.format.channelCount == 1)
        #expect(out.frameLength == 16000)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter AudioMixerTests 2>&1 | tail -15
```

Expected: `AudioMixer` not found.

- [ ] **Step 3: Write `Sources/HarcAudio/AudioMixer.swift`**

```swift
import Foundation
import AVFoundation

/// Resamples incoming mic and system-audio buffers to 16 kHz mono Float32,
/// then sums aligned chunks. Not Sendable — hold on a single actor.
public final class AudioMixer {
    public static let targetSampleRate: Double = 16000
    public static let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioMixer.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private var micConverter: AVAudioConverter?
    private var micInputFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemInputFormat: AVAudioFormat?

    public init() {}

    public func processMic(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(
            buffer,
            converter: &micConverter,
            inputFormat: &micInputFormat,
            label: "mic"
        )
    }

    public func processSystem(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try convert(
            buffer,
            converter: &systemConverter,
            inputFormat: &systemInputFormat,
            label: "system"
        )
    }

    /// Sample-wise sum of two mono 16 kHz buffers, clamped to [-1, 1].
    /// If lengths differ, sums the shorter prefix.
    public func sum(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard mic.format == AudioMixer.targetFormat,
              system.format == AudioMixer.targetFormat
        else {
            throw AudioError.conversionFailed("sum: both inputs must be in target format")
        }
        let frames = min(mic.frameLength, system.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioMixer.targetFormat, frameCapacity: frames) else {
            throw AudioError.conversionFailed("sum: allocation failed")
        }
        out.frameLength = frames
        let m = mic.floatChannelData![0]
        let s = system.floatChannelData![0]
        let o = out.floatChannelData![0]
        for i in 0..<Int(frames) {
            var v = m[i] + s[i]
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            o[i] = v
        }
        return out
    }

    // Number of extra input frames appended to warm up the sinc filter so that
    // the first output sample is stable when using .pre priming.
    private static let primeExtension = 64

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        inputFormat: inout AVAudioFormat?,
        label: String
    ) throws -> AVAudioPCMBuffer {
        if converter == nil || inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: AudioMixer.targetFormat) else {
                throw AudioError.conversionFailed("\(label): no converter for \(buffer.format)")
            }
            // .pre fills the filter delay with the first input sample instead of
            // zeros, eliminating the sinc ramp-up at the start of each chunk.
            c.primeMethod = .pre
            converter = c
            inputFormat = buffer.format
        }

        // Extend the input buffer by primeExtension frames of the same last-sample
        // value so the converter can produce the expected number of output frames
        // even though .pre consumes some input for filter priming.
        let inputFrames = Int(buffer.frameLength)
        let extraInput = AudioMixer.primeExtension
        let totalInput = inputFrames + extraInput
        let channelCount = Int(buffer.format.channelCount)

        guard let extended = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: AVAudioFrameCount(totalInput)
        ) else {
            throw AudioError.conversionFailed("\(label): extended buffer allocation failed")
        }
        extended.frameLength = AVAudioFrameCount(totalInput)

        for ch in 0..<channelCount {
            let src = buffer.floatChannelData![ch]
            let dst = extended.floatChannelData![ch]
            dst.update(from: src, count: inputFrames)
            let lastValue = inputFrames > 0 ? src[inputFrames - 1] : 0.0
            for i in inputFrames..<totalInput { dst[i] = lastValue }
        }

        let expectedOutput = AVAudioFrameCount(
            Double(inputFrames) * AudioMixer.targetSampleRate / buffer.format.sampleRate
        )
        let capacity = expectedOutput + AVAudioFrameCount(extraInput) + 4

        guard let out = AVAudioPCMBuffer(pcmFormat: AudioMixer.targetFormat, frameCapacity: capacity) else {
            throw AudioError.conversionFailed("\(label): output allocation failed")
        }

        var error: NSError?
        var delivered = false
        let status = converter!.convert(to: out, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            delivered = true
            return extended
        }

        if status == .error, let error {
            throw AudioError.conversionFailed("\(label): \(error.localizedDescription)")
        }

        out.frameLength = min(out.frameLength, expectedOutput)
        return out
    }
}
```

**Why the `.pre` + primeExtension dance:** `AVAudioConverter`'s default prime method zeroes the sinc filter's delay line, which produces a low-amplitude ramp-up at the start of each chunk (first sample ~0.325 instead of 0.5 for a constant-0.5 input). Setting `primeMethod = .pre` uses the first input sample to pre-fill the delay line — correct amplitude, but the converter then consumes some input for priming and produces fewer output frames. Appending `primeExtension` frames of the last-sample value before conversion gives the filter enough input to produce the expected output frame count, then we truncate to exact size. The padding is last-sample-hold so the filter state transitions continuously at buffer boundaries (inaudible DC perturbation, well within Parakeet's tolerance).

- [ ] **Step 4: Run the tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter AudioMixerTests 2>&1 | tail -20
```

Expected: all 4 tests pass.

Common wrinkles:
- The resampling test tolerance is `0.05` because `AVAudioConverter` uses a sinc interpolator that introduces tiny overshoot/undershoot at the start. If the first sample is wildly off (e.g. `0.01` instead of `0.5`), the likely cause is the converter skipping the first input block — check that `delivered` only flips once and `haveData` is returned the first time.
- If `AVAudioConverter(from:to:)` returns nil for the mic/system formats, the formats aren't convertible in a single step. For Float32 PCM at typical device rates (44100/48000) this shouldn't happen on macOS 14.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcAudio/AudioMixer.swift Tests/HarcAudioTests/AudioMixerTests.swift
git commit -m "feat: AudioMixer resamples mic + system to 16 kHz mono and sums"
```

---

### Task 5: `MicCapture` — AVAudioEngine input tap

Hardware-bound. `MicCaptureSource` protocol lets `RecordingSession` test against fakes. The real impl is tested only via Task 8's manual smoke.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/MicCapture.swift`

- [ ] **Step 1: Write `Sources/HarcAudio/MicCapture.swift`**

`@preconcurrency import AVFoundation` is required: `AVAudioPCMBuffer` isn't annotated `Sendable` in the SDK yet, so `AsyncStream<AVAudioPCMBuffer>` can't cross the actor boundary in a strict-concurrency build. This is the recommended Swift 6 migration escape hatch for SDK types that haven't been updated yet — it suppresses the Sendable diagnostic without losing real concurrency checking elsewhere.

```swift
import Foundation
@preconcurrency import AVFoundation

/// Minimal protocol so RecordingSession can be tested against fakes.
public protocol MicCaptureSource: Sendable {
    /// Prompt for permission if not yet granted. Throws `AudioError.micPermissionDenied` on refusal.
    func requestPermission() async throws

    /// Start capture. Returns a stream of PCM buffers at the hardware-native format.
    /// The stream finishes after `stop()`.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>

    func stop() async
}

/// Real implementation backed by AVAudioEngine.
public actor MicCapture: MicCaptureSource {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false

    public init() {}

    public func requestPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioError.micPermissionDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw AudioError.micPermissionDenied }
        @unknown default:
            throw AudioError.micPermissionDenied
        }
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if isRunning {
            return AsyncStream { cont in cont.finish() }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [cont] buffer, _ in
            // Copy the buffer — AVAudioEngine reuses the underlying storage.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                return
            }
            copy.frameLength = buffer.frameLength
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let total = Int(buffer.frameLength) * bytesPerFrame
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], total)
                }
            }
            cont.yield(copy)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            throw AudioError.audioEngineFailed(error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    public func stop() async {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isRunning = false
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. No unit tests for this file — it requires real mic hardware.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcAudio/MicCapture.swift
git commit -m "feat: MicCapture AVAudioEngine tap with permission prompt"
```

---

### Task 6: `SystemAudioCapture` — ScreenCaptureKit audio-only

Also hardware-bound. Tested via manual smoke.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/SystemAudioCapture.swift`

- [ ] **Step 1: Write `Sources/HarcAudio/SystemAudioCapture.swift`**

Uses `@preconcurrency import AVFoundation` AND `@preconcurrency import ScreenCaptureKit` — `AVAudioPCMBuffer` and `SCShareableContent` both lack `Sendable` annotations in the SDK.

```swift
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

public protocol SystemAudioCaptureSource: Sendable {
    /// Request screen-recording permission. Throws `AudioError.systemAudioPermissionDenied` on refusal.
    /// First call triggers the TCC prompt.
    func requestPermission() async throws

    /// Start capture. Returns a stream of PCM buffers.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>

    func stop() async
}

/// Real implementation backed by SCStream.
public actor SystemAudioCapture: NSObject, SystemAudioCaptureSource, SCStreamOutput {
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isRunning = false

    public override init() {
        super.init()
    }

    public func requestPermission() async throws {
        // Invoking SCShareableContent triggers the TCC prompt and surfaces denial via error.
        do {
            _ = try await SCShareableContent.current
        } catch {
            throw AudioError.systemAudioPermissionDenied
        }
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if isRunning {
            return AsyncStream { cont in cont.finish() }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AudioError.systemAudioPermissionDenied
        }
        guard let display = content.displays.first else {
            throw AudioError.systemAudioStreamFailed("no display")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // We need a minimal video spec even for audio-only capture.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        } catch {
            throw AudioError.systemAudioStreamFailed("addStreamOutput: \(error.localizedDescription)")
        }

        let (s, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = cont
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            cont.finish()
            throw AudioError.systemAudioStreamFailed("startCapture: \(error.localizedDescription)")
        }
        isRunning = true
        return s
    }

    public func stop() async {
        guard isRunning, let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let buffer = Self.convertToPCM(sampleBuffer) else { return }
        Task { await self.yieldBuffer(buffer) }
    }

    private func yieldBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    /// Convert a CMSampleBuffer from SCStream into a Float32 AVAudioPCMBuffer.
    /// SCStream delivers Int16 or Float32 depending on the system; we route
    /// whatever format the buffer describes and let AudioMixer normalise.
    nonisolated private static func convertToPCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return nil }

        var asbd = streamDesc
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLen = 0
        var ptr: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen,
            dataPointerOut: &ptr
        )
        guard status == kCMBlockBufferNoErr, let src = ptr else { return nil }

        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
           let dst = pcm.floatChannelData {
            // Non-interleaved Float32 — copy per channel. Derive the per-channel
            // stride from the declared frame geometry rather than splitting the
            // observed buffer length, which would be wrong for formats where
            // channel planes aren't equal-sized.
            let perChannelBytes = Int(format.streamDescription.pointee.mBytesPerFrame) * Int(frames)
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src.advanced(by: ch * perChannelBytes), perChannelBytes)
            }
        } else {
            // Interleaved or Int16 — memcpy as a single blob into the raw storage.
            // `audioBufferList` is read-only; use `mutableAudioBufferList` via the pointer wrapper.
            let mutableABL = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            if let raw = mutableABL[0].mData {
                memcpy(raw, src, totalLen)
                mutableABL[0].mDataByteSize = UInt32(totalLen)
            }
        }
        return pcm
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
```

Expected: `Build complete!`.

If the build fails on `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` with the dynamic format (e.g., interleaved Int16 from SCStream), the allocator may reject it. Fallback: construct a non-interleaved Float32 format explicitly and convert via `AVAudioConverter` inside `convertToPCM`. For Plan 3's scope, the straightforward path above works on macOS 14+ where SCStream reliably delivers non-interleaved Float32 — but the `else` branch catches older or interleaved variants.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcAudio/SystemAudioCapture.swift
git commit -m "feat: SystemAudioCapture via SCStream audio-only mode"
```

---

### Task 7: `RecordingSession` actor

Orchestrates everything: permission prompts → capture start → mixer → writer → stop → atomic move. Graceful degradation: if system-audio permission is denied, recording still proceeds with mic-only. Unit-tested against `FakeMicCapture` + `FakeSystemAudioCapture`.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcAudio/RecordingSession.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcAudio

// Sendable box so non-Sendable AVAudioPCMBuffer arrays can be captured in @Sendable
// Task closures. Safe in fakes because the array is immutable after construction.
private final class SendableBuffers: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
}

@Suite("RecordingSession")
struct RecordingSessionTests {
    /// In-memory fake that emits the buffers you hand it, then finishes.
    actor FakeMic: MicCaptureSource {
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
                cont.finish()
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    actor FakeSystem: SystemAudioCaptureSource {
        enum Mode: Sendable { case enabled([AVAudioPCMBuffer]), denied }
        nonisolated let mode: Mode
        private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        init(_ mode: Mode) { self.mode = mode }
        func requestPermission() async throws {
            if case .denied = mode { throw AudioError.systemAudioPermissionDenied }
        }
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            guard case .enabled(let script) = mode else {
                throw AudioError.systemAudioPermissionDenied
            }
            let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            self.continuation = cont
            let box = SendableBuffers(script)
            Task.detached {
                for buf in box.buffers { cont.yield(buf) }
                cont.finish()
            }
            return stream
        }
        func stop() async { continuation?.finish() }
    }

    private func makeConstantBuffer(
        _ value: Float,
        frames: AVAudioFrameCount,
        rate: Double = 16000,
        channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = value }
        }
        return buf
    }

    private func makeTempBase() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp/harc-session-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("session writes a WAV at the destination and returns its URL")
    func writesWAVAtDestination() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let mic = FakeMic(script: [
            makeConstantBuffer(0.2, frames: 16000),
            makeConstantBuffer(0.2, frames: 16000),
        ])
        let sys = FakeSystem(.enabled([
            makeConstantBuffer(0.1, frames: 16000),
            makeConstantBuffer(0.1, frames: 16000),
        ]))
        let destination = RecordingDestination(baseDirectory: base)

        let session = RecordingSession(
            mic: mic,
            systemAudio: sys,
            destination: destination
        )

        try await session.start(at: Date())
        // Wait briefly for fake streams to drain.
        try await Task.sleep(nanoseconds: 300_000_000)
        let url = try await session.stop()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(base.path))
        #expect(url.pathExtension == "wav")

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length >= 16000, "expected ≥1s recorded, got \(file.length) frames")
    }

    @Test("session gracefully degrades to mic-only when system audio permission is denied")
    func degradesMicOnly() async throws {
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let mic = FakeMic(script: [makeConstantBuffer(0.3, frames: 16000)])
        let sys = FakeSystem(.denied)
        let destination = RecordingDestination(baseDirectory: base)

        let session = RecordingSession(mic: mic, systemAudio: sys, destination: destination)
        try await session.start(at: Date())
        try await Task.sleep(nanoseconds: 200_000_000)
        let url = try await session.stop()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length >= 15000, "expected ~1s recorded with mic-only, got \(file.length) frames")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingSessionTests 2>&1 | tail -15
```

Expected: `RecordingSession` not found.

- [ ] **Step 3: Write `Sources/HarcAudio/RecordingSession.swift`**

```swift
import Foundation
@preconcurrency import AVFoundation

/// Orchestrates a single recording. One instance per recording.
public actor RecordingSession {
    private let mic: any MicCaptureSource
    private let systemAudio: any SystemAudioCaptureSource
    private let destination: RecordingDestination

    // Processing state accessed from the pump task via nonisolated(unsafe).
    // Safe because the pump task is serialised: it runs sequentially (one buffer
    // at a time), and RecordingSession.stop() cancels + awaits the pump before
    // touching mixer or writer.
    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?

    private var cacheURL: URL?
    private var startedAt: Date?
    private var pumpTask: Task<Void, Never>?
    private var systemAudioAvailable = false

    public init(
        mic: any MicCaptureSource,
        systemAudio: any SystemAudioCaptureSource,
        destination: RecordingDestination
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.destination = destination
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

    public func stop() async throws -> URL {
        await mic.stop()
        await systemAudio.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        guard let writer, let cache = cacheURL, let startedAt else {
            throw AudioError.audioEngineFailed("stop called before start")
        }
        try writer.close()

        let dst = try destination.publicPath(for: startedAt)
        try RecordingDestination.atomicMove(from: cache, to: dst)
        self.writer = nil
        return dst
    }

    // Called from pumpStreams. Because mixer and writer are nonisolated(unsafe),
    // this can be nonisolated — no actor hop required, no Sendable issues.
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

/// Free nonisolated function: iterates the mic stream, zips with the system stream (if any),
/// and calls the nonisolated processPair on the session. Running as a free function means
/// AsyncStream iterators (non-Sendable) stay as local vars and never cross isolation boundaries.
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

**Swift 6 note on the `nonisolated(unsafe)` + free-function pump:** `AsyncStream.Iterator` isn't `Sendable`, and `AVAudioPCMBuffer` isn't either. Keeping the pump as an actor-isolated method would require feeding both through a Sendable boundary, which is impossible without rewriting Apple's types. Instead we lift the pump into a free function that holds the iterator as a local variable — nothing crosses isolation. `processPair` is `nonisolated` so it can be called without a hop, and `mixer`/`writer` are `nonisolated(unsafe)` so that method can touch them. The safety argument: only the pump task accesses `mixer` and `writer` during recording, it's single-threaded (one buffer at a time), and `stop()` on the actor cancels + awaits the pump before touching `writer` to close it.

- [ ] **Step 4: Run the tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingSessionTests 2>&1 | tail -15
```

Expected: both tests pass.

If `writesWAVAtDestination` fails with "expected ≥1s recorded" at <16000 frames, the pump loop may be dropping data due to timing. Increase the `Task.sleep` in the test before `stop()` to `500_000_000` (500 ms) and re-run; the fakes emit buffers from a detached Task so the pump needs a moment to consume them.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 33 tests in 12 suites (prior 29 + 2 new, plus the 2 fake-driven session tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcAudio/RecordingSession.swift Tests/HarcAudioTests/RecordingSessionTests.swift
git commit -m "feat: RecordingSession actor orchestrating mic+system+mixer+writer"
```

---

### Task 8: Wire a Start/Stop Recording menu item into `Harc.app`

The final step — minimal UI integration so the user (and the reviewer) can actually record. The Plan 5 popover replaces this, but it's the cleanest way to exercise Plan 3 end-to-end.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Rewrite `HarcApp/AppDelegate.swift`**

```swift
import AppKit
import HarcAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?
    private var session: RecordingSession?

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
        let session = RecordingSession(
            mic: MicCapture(),
            systemAudio: SystemAudioCapture(),
            destination: RecordingDestination(baseDirectory: RecordingDestination.defaultBaseDirectory())
        )
        self.session = session
        startMenuItem?.isEnabled = false
        stopMenuItem?.isEnabled = true
        if let item = statusItem { updateMenuBarIcon(recording: true, on: item) }

        Task {
            do {
                try await session.start(at: Date())
            } catch {
                await MainActor.run { self.presentError(error) }
                await MainActor.run { self.resetUI() }
            }
        }
    }

    @objc private func stopRecording() {
        guard let session else { return }
        Task {
            do {
                let url = try await session.stop()
                await MainActor.run { self.notifyRecordingSaved(url: url) }
            } catch {
                await MainActor.run { self.presentError(error) }
            }
            await MainActor.run { self.resetUI() }
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

    private func notifyRecordingSaved(url: URL) {
        let alert = NSAlert()
        alert.messageText = "Recording saved"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
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

- [ ] **Step 2: Regenerate Xcode project and build**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate
xcodebuild \
  -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The app now links `HarcAudio` and has the new menu items.

- [ ] **Step 3: Manual smoke test**

```bash
cd /Users/jlane/GitHub/Harc
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
open "$APP"
```

Manual steps:
1. Click the waveform icon in the menu bar → "Start Recording" (⌘R).
2. macOS prompts for **Microphone** access → Allow.
3. macOS prompts for **Screen & System Audio Recording** → Allow (or Deny to test mic-only path).
4. Play audio on the system for ~10 seconds; speak into the mic.
5. Click menu bar → "Stop Recording" (⌘S). A "Recording saved" alert appears with the path.
6. Click "Reveal in Finder" — confirm the `.wav` lives at `~/Documents/Harc/2026/2026-04-17/HH-mm-ss.wav`.
7. Open the WAV in QuickTime Player; confirm both mic and system audio are present (if screen-recording permission was granted).

If TCC prompts fail to appear, the app may need to be re-codesigned after each change — `open` launches the built `.app` but macOS caches TCC decisions by code signature. Running from Xcode (⌘R) sometimes re-prompts; toggling Microphone on/off in System Settings → Privacy & Security → Microphone resets the per-app decision.

- [ ] **Step 4: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "feat: Start/Stop Recording menu items wired to RecordingSession"
```

---

## Acceptance Criteria (Plan 3 complete when all true)

- `swift test` passes all existing + new HarcAudioTests. Expect ~33 tests in 12 suites.
- `swift build` clean; `swift build -Xswiftc -strict-concurrency=complete` clean.
- `xcodegen generate && xcodebuild ... build` succeeds; `codesign --verify --deep --strict Harc.app` green.
- Launching `Harc.app` shows the waveform icon + "Start Recording" / "Stop Recording" / "Quit Harc" menu items.
- ⌘R triggers a recording; TCC prompts for mic + screen recording appear on first run.
- ⌘S stops the recording; an alert reports the destination URL.
- The destination WAV opens in QuickTime and plays back both mic and system audio (assuming both permissions granted).
- File system state matches: in-progress recording at `~/Library/Caches/Harc/recordings/<uuid>.wav`, then atomically moved to `~/Documents/Harc/YYYY/YYYY-MM-DD/HH-mm-ss.wav` on stop.
- Recording still works with screen-recording permission denied (mic-only path, confirmed by the RecordingSession unit test).
- 8 new commits on `main`.

## Open Decisions (for future plans)

- **VAD / silence gating** — CLAUDE.md notes meeting audio is 40–70% silence. Plan 3 captures every byte. Plan 3a could layer VAD to cut transcription work; requires a decision on whether to drop silent frames from the WAV or keep them with markers. Not urgent.
- **Chunking boundary signal** — Plan 4 needs the rolling 60-second chunk boundary. AudioFileWriter exposes the current frame count; the chunker can poll it. Or `RecordingSession` can gain a `writtenFrames` accessor. Decide in Plan 4.
- **Buffer format from `SCStream`** — on macOS 14+, ScreenCaptureKit appears to deliver non-interleaved Float32. If a future OS version changes this, the fallback branch in `SystemAudioCapture.convertToPCM` handles it by copying into interleaved storage; AudioMixer's `AVAudioConverter` accepts either.

## Self-Review

**Spec coverage (Plan 1's Plan 3 sketch):**

- "AVAudioEngine taps the default input device" → Task 5 `MicCapture`.
- "ScreenCaptureKit (SCStream with audioOnly) taps system audio" → Task 6 `SystemAudioCapture`.
- "Mix both into 16 kHz mono Float32 buffers" → Task 4 `AudioMixer`.
- "Stream through an AudioFileWriter to ~/Library/Caches/Harc/recordings/<uuid>.wav" → Task 3 `AudioFileWriter` + Task 7 `RecordingSession` cache path.
- "fsync every N seconds" → Task 3 `fsyncIfDue`, 5-second interval.
- "Atomically move into the configured destination folder under YYYY/YYYY-MM-DD/HH-mm-ss.wav" → Task 2 `RecordingDestination.publicPath` + `atomicMove`, Task 7 calls them on stop.
- "Permission handling for microphone + screen recording" → Task 5, Task 6 `requestPermission`.
- "Graceful degradation to mic-only when screen-recording is denied" → Task 7 `RecordingSession.start` catches `.systemAudioPermissionDenied` and proceeds mic-only; tested in RecordingSessionTests.
- "Synthetic audio input → verify WAV header, sample rate, frame count" → Task 3 AudioFileWriterTests.

**Placeholder scan:** no `TODO`, `TBD`, or "fill in details" patterns in any task. Task 3 `AudioFileWriter.close()` has a known comment ("Dropping the reference triggers finalization") — that's documentation, not a placeholder.

**Type consistency:**
- `AVAudioPCMBuffer` flows end-to-end through `MicCaptureSource` / `SystemAudioCaptureSource` / `AudioMixer` / `AudioFileWriter`.
- `RecordingSession.init(mic:systemAudio:destination:)` matches `RecordingSession(mic: MicCapture(), systemAudio: SystemAudioCapture(), destination: RecordingDestination(...))` in AppDelegate (Task 8).
- `AudioError` cases used in every module match the enum declared in Task 1.
- `RecordingDestination.publicPath(for:)` and `.atomicMove(from:to:)` and `.cachePath()` all defined in Task 2 and consumed in Task 7.
- `AudioMixer.targetFormat` — 16 kHz mono Float32 — matches `AudioFileWriter.targetSampleRate` / `targetChannels` values (16 000 / 1). Writer is Int16 on disk but accepts Float32 buffers (AVAudioFile handles the conversion).
