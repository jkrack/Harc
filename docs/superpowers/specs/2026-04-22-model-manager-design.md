# Model Manager + Settings Shelf Design Doc

**Feature:** A curated, on-disk catalog of optional local models (Gemma 4 summarization tiers, a text embedding model for semantic search) that the user downloads from Settings on demand. Downloads are resumable, verified against a bundled manifest, and gated by disk-space / RAM sanity checks. Features that need a model prompt the user to install one instead of silently failing.
**Date:** 2026-04-22
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Harc has committed to a local-first posture. Honest local summarization + semantic search require additional models beyond Parakeet — at minimum a 1–2 GB Gemma 4 E2B, optionally a 2–3 GB E4B or 14–16 GB 26B-A4B, plus a ~100 MB text embedding model. Three gaps we need to close together, not one at a time:

- **We can't bundle them.** Even a 1.5 GB E2B would double the `.app` size and blow past any sane DMG budget.
- **Users shouldn't BYO.** Locked in earlier: arbitrary model files are a support hole (wrong chat template, wrong quant, wrong tokenizer, silent quality regressions). The opinionated shelf is the product.
- **Heavy work goes to down moments.** Downloads and installs belong in Settings under the user's control, never in the middle of a meeting.

**User story (first install).** "I open Harc for the first time. Everything works — recording, transcription, the library. Later I click **Summarize** on a meeting and Harc says *'This needs the Gemma 4 Standard model — 1.5 GB. Download?'* I say yes, it downloads in the background, and the button comes back to life."

**User story (upgrading).** "I'm on an M3 Max with 64 GB of RAM. In Settings → Models I see *Standard · installed*, *Quality · available (2.5 GB)*, *Max · available (15 GB)*. I click Download on Max. Harc warns it'll take ~10 min on my connection; I agree. When done, a radio button lets me pick which tier runs."

**User story (disk reclaim).** "I installed Max last month, never used it. In Settings → Models I hit **Remove** on Max. It's gone; 15 GB is back. Standard stays as my active model."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new `HarcModels` Swift package target (library) under `Sources/HarcModels/` that owns:
  - `ModelCatalog` — a hard-coded, versioned list of shipped models.
  - `ModelDescriptor` — per-model metadata (id, tier, task, display name, MLX HF repo, files, total bytes, SHA256 manifest, min macOS, min RAM, recommended RAM).
  - `ModelInstallState` — `.absent | .downloading(progress) | .installed | .verifying | .failed(reason)`.
  - `ModelManager` actor — single source of truth for install state, download lifecycle, disk verification, delete.
  - `ModelStorage` — path utilities (`~/Library/Application Support/Harc/Models/<model-id>/`, lockfile, partial-download state).
- A `ModelsSettingsView` page in HarcUI rendered as a new tab in `SettingsView`, between **Transcription** and **Storage**.
- Disk-space sanity check before starting a download (refuse when free < requiredBytes + 10 % headroom) and a soft warning when the user's `ProcessInfo.physicalMemory` falls below the model's recommended RAM.
- An `activeSummarizerID` preference (default `"gemma-4-e2b-it-4bit"`) picked from the installed summarizer tier. Changes on install / remove.
- An `activeEmbedderID` preference (default `"bge-small-en-v1.5"`) — same mechanism.
- A public `ModelManager.awaitInstalled(_:)` API that features use to gate their UI: it resolves immediately if the model is installed, otherwise kicks the caller's view into the "needs install" branch.
- A `ModelRequirementView` reusable card used wherever a feature needs a model (summary pane, semantic search tab) — renders model info + **Install** + **Later**. Wraps `awaitInstalled` and `ModelManager.startDownload`.
- Tests for the manifest decoder, disk-space guard, the path utilities, and a fake-URLSession download round-trip with SHA mismatch, resume, and cancel.

**Out of scope / non-goals (v1):**

- **Remote-hosted manifests.** The catalog is compiled into the app. A future v2 can fetch a signed JSON over HTTPS for hot-swapping without an app release; for v1 the catalog ships with the binary.
- **BYO models of any kind.** No file pickers, no "custom URL" fields. If a user wants a model we don't ship, the answer is "file an issue."
- **Background / overnight downloads.** v1 foregrounds the download via `URLSession.default` (app must be running). `URLSessionConfiguration.background` support deferred — the download cancels cleanly if the user quits.
- **Delta / incremental updates.** If we change a model file, users re-download the whole model. Cheap-enough given how rarely a curated entry flips.
- **Parakeet STT model management.** FluidAudio already owns downloading and caching the Parakeet + diarizer weights via its own `AsrModels.downloadAndLoad(version:)` / `DiarizerModels.download()` paths. The new `ModelManager` does NOT touch those — they stay where they are.
- **Auto-cleanup of stale partial downloads on launch.** We clean partial state only when a new download starts on the same model. Left-behind bytes from a prior crash live under Models/ until then; small enough risk, not worth a launch-time scanner.
- **Non-ARM64 support.** Harc is Apple Silicon only (per CLAUDE.md); MLX weights are native arm64.
- **Concurrent multi-model downloads.** A user can only have one download running at a time. Queue the rest.

---

## 3. Data shape

### 3.1 Catalog (hardcoded, versioned)

```swift
// HarcModels/ModelCatalog.swift
public enum ModelTask: String, Codable, Sendable {
    case summarizer
    case textEmbedder
}

public enum ModelTier: String, Codable, Sendable {
    case standard     // fits any M-series, 16 GB+
    case quality      // 16 GB+
    case max          // 32 GB+
    case singleton    // non-tiered; one-of per task (e.g. the embedder)
}

public struct ModelFile: Codable, Sendable, Equatable {
    public let path: String        // relative; e.g. "config.json", "model.safetensors"
    public let bytes: Int64
    public let sha256: String
    public let url: URL            // resolved CDN URL (https://huggingface.co/…/resolve/main/…)
}

public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String          // stable; e.g. "gemma-4-e2b-it-4bit"
    public let displayName: String // "Gemma 4 · Standard"
    public let task: ModelTask
    public let tier: ModelTier
    public let description: String // shown in Settings
    public let repoID: String      // "mlx-community/gemma-4-e2b-it-4bit"
    public let revision: String    // git SHA pinned
    public let files: [ModelFile]
    public let totalBytes: Int64   // sum of files[].bytes; cached for UI
    public let minMacOS: String    // e.g. "14.0"
    public let minRAMGB: Int
    public let recommendedRAMGB: Int
    public let contextTokens: Int  // prompt budget
}

public enum ModelCatalog {
    /// Hardcoded, versioned list. Changing this list warrants a code review.
    public static let v1: [ModelDescriptor] = [
        // Gemma 4 summarizers — three tiers.
        ModelDescriptor(id: "gemma-4-e2b-it-4bit", displayName: "Gemma 4 · Standard",
                        task: .summarizer, tier: .standard, …),
        ModelDescriptor(id: "gemma-4-e4b-it-4bit", displayName: "Gemma 4 · Quality",
                        task: .summarizer, tier: .quality, …),
        ModelDescriptor(id: "gemma-4-26b-a4b-it-4bit", displayName: "Gemma 4 · Max",
                        task: .summarizer, tier: .max, …),
        // Text embedder for semantic search.
        ModelDescriptor(id: "bge-small-en-v1.5", displayName: "BGE · English",
                        task: .textEmbedder, tier: .singleton, …),
    ]
}
```

File manifests (URL + sha256 + size per file) are generated once per model via a build-time script (`scripts/refresh-model-manifests.swift`) that hits the HuggingFace API with the pinned revision and writes the `[ModelFile]` array into the descriptor. We do not fetch the manifest at runtime — it's frozen on release.

### 3.2 On-disk layout

```
~/Library/Application Support/Harc/
  Models/
    gemma-4-e2b-it-4bit/
      config.json
      tokenizer.json
      model.safetensors
      .harc-install.json      ← written on success: { "revision": "...", "installedAt": "2026-04-22T…", "bytes": 1523948032 }
      .harc-download.partial  ← present only during an active download
```

- Presence of `.harc-install.json` is the single source of truth for "installed."
- Presence of `.harc-download.partial` (a tiny JSON describing which files are done and how many bytes each has) means "resumable."
- A model is never "installed and partially downloading" at the same time — start-of-download deletes the prior install if any.

### 3.3 Preferences (existing `HarcPreferences`)

Two new columns, both `String` defaults:

```swift
@Published public var activeSummarizerID: String   // default "gemma-4-e2b-it-4bit" even if not installed
@Published public var activeEmbedderID: String     // default "bge-small-en-v1.5" even if not installed
```

Setting a value whose descriptor doesn't exist in `ModelCatalog.v1` is ignored on read (falls back to default). Setting a value whose descriptor exists but isn't installed is legal — callers of `ModelManager.awaitInstalled(id:)` resolve that at runtime.

---

## 4. Download lifecycle

### 4.1 State machine

```
 absent  ──startDownload──▶  downloading  ──allFilesDone──▶  verifying
   ▲                            │                                │
   │                          cancel                          sha ok ▼
   │                            ▼                             installed
   │                         absent (partial saved for resume)    │
   └──────────────remove────────────────────────────────────── ───┘

  any state ──unrecoverable error──▶  failed(reason)
  failed    ──retry──▶  downloading
  failed    ──discard──▶ absent
```

### 4.2 Public API

```swift
public actor ModelManager {
    public func state(of id: String) -> ModelInstallState
    public func startDownload(_ id: String) throws
    public func cancel(_ id: String)
    public func remove(_ id: String) throws

    /// Resolves immediately if installed; otherwise throws `.notInstalled`.
    /// Features use this as the install gate.
    public func requireInstalled(_ id: String) throws -> URL

    /// Async stream of state transitions. UI subscribes with
    /// `.onReceive(manager.stateChanges(id: ...))`.
    public nonisolated func stateChanges(id: String) -> AsyncStream<ModelInstallState>
}
```

A single shared `ModelManager` instance lives on the AppDelegate (like `autoStop`). Exposed to SwiftUI via `.environmentObject`.

### 4.3 Download plumbing

- One `URLSession` with `URLSessionConfiguration.default`, `httpMaximumConnectionsPerHost = 2`.
- Files downloaded sequentially (not in parallel) — simpler resume and bandwidth predictability.
- `URLSessionDownloadTask` per file with `resumeData` persisted to disk on cancel / failure / quit.
- Each file's partial is stored at `<model-dir>/.harc-download.partial/<path>.part` and finalized with `FileManager.moveItem` on byte-count + sha match.
- SHA256 verified per file in a detached Task after move; failure tears down the install and surfaces `.failed(.checksumMismatch)`.
- Progress aggregated across files → single `progress: Double` on the state (bytes done / total bytes).

### 4.4 Disk / RAM guards

Before `startDownload`:

- Disk free on the Application Support volume must be ≥ `totalBytes × 1.1`. Otherwise throw `.insufficientDisk(required:, free:)`.
- Physical RAM < descriptor's `minRAMGB` → refuse outright. `< recommendedRAMGB` → warn in the UI but allow. Both pure display — the download itself is RAM-independent.

---

## 5. UI — `ModelsSettingsView`

A new tab rendered by `SettingsView`, between Transcription and Storage.

### 5.1 Layout

```
┌────────────────────────────────────────────────────────┐
│  Models                                                │
│  Harc runs all AI work locally. Download only the     │
│  tiers you need.                                       │
│                                                        │
│  Summarization                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ ○ Gemma 4 · Standard     Installed · 1.5 GB      │  │
│  │   Good summaries in 20–40 s per hour of audio.   │  │
│  │   16 GB+ RAM                          [Remove]   │  │
│  ├──────────────────────────────────────────────────┤  │
│  │ ○ Gemma 4 · Quality      Not installed · 2.5 GB  │  │
│  │   Clearly better. 40–90 s per hour.              │  │
│  │   16 GB+ RAM                         [Download]  │  │
│  ├──────────────────────────────────────────────────┤  │
│  │ ○ Gemma 4 · Max          Not installed · 15 GB   │  │
│  │   Best quality; needs a Mac Studio or 32 GB M3.  │  │
│  │   ⚠︎ Your Mac has 16 GB — not recommended        │  │
│  │                                      [Download]  │  │
│  └──────────────────────────────────────────────────┘  │
│  Active model: ○ Standard  ○ Quality  ○ Max           │
│                                                        │
│  Semantic search                                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │ BGE · English            Installed · 130 MB      │  │
│  │   Used for "find where I mentioned X" search.   │  │
│  │                                       [Remove]   │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

### 5.2 Interactions

- **Download:** disk check → warn if insufficient RAM → start download → row swaps in a progress bar with `Cancel` and an ETA `(downloaded / totalBytes × elapsed / downloaded)`. Background failure raises a non-modal banner at the top of the tab with retry / dismiss.
- **Remove:** confirmation alert ("Remove Gemma 4 · Quality? 2.5 GB will be freed."). On confirm, `ModelManager.remove(_:)` deletes the directory. If the removed model was the `activeSummarizerID`, roll back to the highest-installed tier; if none installed, roll back to the default `id` even if absent — calls to the feature will prompt to install.
- **Active radio:** only installed summarizers are selectable. Selecting one writes `HarcPreferences.activeSummarizerID`. The embedder has exactly one entry so no radio — just Install / Remove.

### 5.3 Inline install prompt — `ModelRequirementView`

```swift
public struct ModelRequirementView: View {
    public let descriptor: ModelDescriptor
    public let onCancel: () -> Void
    ...
}
```

Renders in place wherever a feature needs a not-installed model:

```
┌────────────────────────────────────────────────┐
│  🧠  Needs Gemma 4 · Standard                  │
│  Harc summarizes transcripts locally using a   │
│  1.5 GB model. Download once; no cloud.        │
│                 [Download 1.5 GB]  [Later]     │
└────────────────────────────────────────────────┘
```

Tapping Download kicks off `ModelManager.startDownload` and the card swaps into a progress variant. Tapping Later collapses to a single-line "Install Gemma 4 to summarize →" link.

---

## 6. Integration points (stubbed for v1, wired in dependent specs)

- **Summarization** (see `2026-04-22-local-summarization-design.md`): `ModelManager.requireInstalled(prefs.activeSummarizerID)` before loading via mlx-swift.
- **Semantic search** (see `2026-04-22-semantic-search-design.md`): `ModelManager.requireInstalled(prefs.activeEmbedderID)` before embedding query / indexing.
- **Speaker re-ID** (see `2026-04-22-speaker-reid-design.md`): bundled in-app, NOT routed through ModelManager. The model's small (~20 MB) and it's enabled-by-default so download ceremony would be user-hostile.
- **Beam search refinement** (see `2026-04-22-beam-search-refinement-design.md`): uses the existing Parakeet weights managed by FluidAudio — no interaction with ModelManager.

---

## 7. Test plan

### 7.1 Unit tests (HarcModelsTests)

- `ModelCatalog.v1.map(\.id)` has no duplicates; every file URL is https; every SHA256 is 64 hex chars; `totalBytes == files.map(\.bytes).reduce(0, +)`.
- `ModelStorage.modelDirectory(for:)` returns the expected path for a fake `descriptor.id`.
- `DiskSpaceGuard.hasSpace(forBytes:volume:)` returns false when free < required × 1.1 using an injectable `FileManager` mock.
- `ModelInstallState` equality across transitions — ensures Combine `removeDuplicates` doesn't drop distinct progress ticks when they share a phase.

### 7.2 Integration tests

- `ModelManagerDownloadTests` uses an in-process fake URLProtocol that serves a 3-file "model" from bytes-in-memory:
  - Happy path: `startDownload` → `.downloading(progress: 0…1)` → `.verifying` → `.installed` with `.harc-install.json` written.
  - SHA mismatch on file 2 → `.failed(.checksumMismatch)`; install dir cleaned up; `.harc-download.partial` remains for resume.
  - Cancel midway through file 2 → `.absent` with partial preserved; resumed download picks up without re-downloading file 1.
  - Disk full (mocked via `DiskSpaceGuard`) → `startDownload` throws `.insufficientDisk` before any network traffic.

### 7.3 UI smoke tests (HarcUITests)

- `ModelsSettingsView` renders one row per descriptor; Active radio is disabled for non-summarizer entries; Download button hidden when `.installed`.
- `ModelRequirementView` collapses to the inline prompt when `descriptor` is not installed and expands to a progress card during download.

---

## 8. Rollout

- v1 ships with `ModelCatalog.v1` encoded in the app. No runtime manifest fetch.
- First release: Settings → Models shows 4 rows (3 summarizer tiers + 1 embedder). Nothing installed by default — same install experience for upgraders and fresh users.
- Dependent features (summarization, semantic search) ship disabled until their model is installed. `ModelRequirementView` is the one bridging UI.
- Post-v1: remote manifest, automatic updates on revision change, background download support. Out of scope here.

---

## 9. Open questions

- **Signed manifest now vs later?** v1 relies on the app binary's own signing for manifest integrity (the `ModelDescriptor`s are in the compiled binary). If we ever move to remote manifests, we'll need a signed JSON + public-key verification. For v1, I'd rather ship and wait.
- **Should MLX model files live in a shared cache across users?** No — single-user Mac accounts are the norm for this product, and Application Support is per-user. Avoids permissions headaches.
- **Retry policy on transient network failure during download?** v1 surfaces `.failed` with a retry button. No silent retries — the user stays in control per the "heavy work in down moments" principle.
