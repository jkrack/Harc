import Foundation

/// Hardcoded, versioned list of shipped models.
///
/// Changing `v1` requires a code change — that's the point. Descriptors name
/// specific pinned revisions from `mlx-community` so a model's weights can't
/// silently change out from under users.
///
/// ## Manifest completeness
///
/// `ModelFile.sha256` is allowed to be an empty string, which means
/// "don't verify a checksum for this file" — a pragmatic release valve for
/// ship-now-before-the-refresh-script-exists. The long-term plan (see
/// `scripts/refresh-model-manifests.swift` in the design doc) is to populate
/// real SHA256s for every file from the HuggingFace API at release time.
///
/// The file paths and URLs below are best-effort based on published
/// `mlx-community/gemma-4-*-4bit` layouts: MLX model repos typically contain
/// `config.json`, `tokenizer.json`, `tokenizer_config.json`,
/// `special_tokens_map.json`, and one or more `model-<nnnnn>-of-<mmmmm>.safetensors`
/// shards with a `model.safetensors.index.json` manifest. If a specific
/// published model adds or renames files, the refresh script will reconcile.
public enum ModelCatalog {

    public static let v1: [ModelDescriptor] = [
        gemma4_E2B_IT_4bit,
        gemma4_E4B_IT_4bit,
        gemma4_26B_A4B_IT_4bit,
        bgeSmallEnV15,
    ]

    /// Lookup helper — nil if the id isn't in the catalog.
    public static func descriptor(for id: String) -> ModelDescriptor? {
        v1.first { $0.id == id }
    }

    /// First-run / hard-fallback summarizer id. Mirrors the default written
    /// by `HarcPreferences`; drift between the two would mean a removed
    /// active summarizer rolls over to a model the user never sees as
    /// "default" in Settings. Tested in `ModelCatalogFallbackTests`.
    public static let defaultSummarizerID = "gemma-4-e2b-it-4bit"

    /// Pick the new active summarizer when the current one is being removed.
    /// Returns the highest-tier summarizer that's still installed (excluding
    /// the one being removed); falls back to `defaultSummarizerID` when no
    /// other summarizer is installed. The default may itself be uninstalled —
    /// that's intentional: the UI then prompts the user to download it.
    public static func fallbackSummarizerID(
        installed: Set<String>,
        excluding excluded: String,
        catalog: [ModelDescriptor] = ModelCatalog.v1
    ) -> String {
        let candidates = catalog
            .filter { $0.task == .summarizer && $0.id != excluded && installed.contains($0.id) }
            .sorted { $0.tier > $1.tier }
        return candidates.first?.id ?? defaultSummarizerID
    }

    /// All descriptors for a given task, ordered: non-singleton tiers asc,
    /// then singletons.
    public static func descriptors(for task: ModelTask) -> [ModelDescriptor] {
        v1.filter { $0.task == task }.sorted { a, b in
            if a.tier == .singleton && b.tier != .singleton { return false }
            if b.tier == .singleton && a.tier != .singleton { return true }
            return a.tier < b.tier
        }
    }

    // ─── Descriptors ──────────────────────────────────────────────────────
    //
    // File byte sizes below are approximations pulled from the HuggingFace
    // UI; they'll be tightened when the refresh script runs. SHA256 is empty
    // pending the same pass. `revision` is "main" for v1 — we pin to a
    // specific SHA once the script lands.
    //
    // Rationale for the picks (from the design doc):
    //   - Gemma 4 E2B-it-4bit: default, ~1.5 GB, fits any M-series
    //   - Gemma 4 E4B-it-4bit: quality tier, ~2.5 GB
    //   - Gemma 4 26B-A4B-it-4bit: max tier, ~15 GB (MoE — 26 B params in
    //     memory, ~4 B activated so compute is E4B-equivalent)
    //   - BGE-small-en-v1.5: singleton embedder for semantic search

    // Verified 2026-04-23 against HuggingFace tree view. Byte counts come
    // from the HF UI's human-readable sizes (MiB/GB rounded); SHA256 is
    // still empty pending a proper refresh script — download verifies by
    // byte count (±1 %) only.
    private static let gemma4_E2B_IT_4bit = ModelDescriptor(
        id: "gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 · Standard",
        summary: "MoE E2B instruction-tuned, 4-bit MLX. 3.6 GB on disk; ~20–40 s per hour of audio.",
        task: .summarizer,
        tier: .standard,
        repoID: "mlx-community/gemma-4-e2b-it-4bit",
        revision: "main",
        files: [
            file("config.json", bytes: 6_000,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("generation_config.json", bytes: 208,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("chat_template.jinja", bytes: 16_300,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("processor_config.json", bytes: 902,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("tokenizer.json", bytes: 32_200_000,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("tokenizer_config.json", bytes: 2_100,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("model.safetensors.index.json", bytes: 230_000,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
            file("model.safetensors", bytes: 3_580_000_000,
                 repo: "mlx-community/gemma-4-e2b-it-4bit"),
        ],
        minRAMGB: 8,
        recommendedRAMGB: 16,
        contextTokens: 32_000,
        manifestVerified: true
    )

    private static let gemma4_E4B_IT_4bit = ModelDescriptor(
        id: "gemma-4-e4b-it-4bit",
        displayName: "Gemma 4 · Quality",
        summary: "Clearly better summaries. 40–90 s per hour. 16 GB RAM recommended.",
        task: .summarizer,
        tier: .quality,
        repoID: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "main",
        files: mlxGemmaFiles(
            base: "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/resolve/main",
            shardCount: 1,
            approximateBytes: 2_500_000_000
        ),
        minRAMGB: 16,
        recommendedRAMGB: 16,
        contextTokens: 32_000
    )

    private static let gemma4_26B_A4B_IT_4bit = ModelDescriptor(
        id: "gemma-4-26b-a4b-it-4bit",
        displayName: "Gemma 4 · Max",
        summary: "Highest quality. Runs E4B-speed via MoE. Requires a Mac Studio or 32 GB+ M-series.",
        task: .summarizer,
        tier: .max,
        repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
        revision: "main",
        files: mlxGemmaFiles(
            base: "https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit/resolve/main",
            shardCount: 4,
            approximateBytes: 15_000_000_000
        ),
        minRAMGB: 24,
        recommendedRAMGB: 32,
        contextTokens: 32_000
    )

    // NOTE — `mlx-community/bge-small-en-v1.5` does NOT exist on HuggingFace
    // as of 2026-04-23; attempting to download it returns HTTP 401. We ship
    // the descriptor so the Settings UI can render a "Semantic search is
    // waiting for an embedder" row, but `manifestVerified: false` makes the
    // Download button inactive. The real repo id + file list will land
    // alongside the semantic-search feature implementation.
    private static let bgeSmallEnV15 = ModelDescriptor(
        id: "bge-small-en-v1.5",
        displayName: "English text embedder",
        summary: "Powers Related-meaning search. Not yet available — pending an MLX-ported embedder.",
        task: .textEmbedder,
        tier: .singleton,
        repoID: "mlx-community/bge-small-en-v1.5",
        revision: "main",
        files: mlxEmbedderFiles(
            base: "https://huggingface.co/mlx-community/bge-small-en-v1.5/resolve/main",
            approximateBytes: 130_000_000
        ),
        minRAMGB: 8,
        recommendedRAMGB: 8,
        contextTokens: 512,
        manifestVerified: false
    )

    // ─── File-list helpers ────────────────────────────────────────────────
    //
    // Real manifests come from the refresh script. These helpers build a
    // plausible file list so the UI and storage layer can be exercised now.
    // SHA256 is left empty — see the big comment at the top of this type.

    /// Convenience for a single-file entry against `mlx-community/<repo>`
    /// on `main`. Used by entries whose file list has been hand-verified.
    private static func file(_ path: String, bytes: Int64, repo: String) -> ModelFile {
        ModelFile(
            path: path,
            bytes: bytes,
            sha256: "",
            url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
        )
    }

    private static func mlxGemmaFiles(base: String, shardCount: Int, approximateBytes: Int64) -> [ModelFile] {
        let configs: [(String, Int64)] = [
            ("config.json", 4_000),
            ("tokenizer.json", 17_000_000),
            ("tokenizer_config.json", 60_000),
            ("special_tokens_map.json", 5_000),
        ]
        let weightBytes = max(0, approximateBytes - configs.map(\.1).reduce(0, +))
        let perShard = shardCount > 0 ? weightBytes / Int64(shardCount) : 0

        var files: [ModelFile] = configs.map { (path, bytes) in
            ModelFile(
                path: path,
                bytes: bytes,
                sha256: "",
                url: URL(string: "\(base)/\(path)")!
            )
        }

        if shardCount == 1 {
            files.append(ModelFile(
                path: "model.safetensors",
                bytes: perShard,
                sha256: "",
                url: URL(string: "\(base)/model.safetensors")!
            ))
        } else {
            files.append(ModelFile(
                path: "model.safetensors.index.json",
                bytes: 20_000,
                sha256: "",
                url: URL(string: "\(base)/model.safetensors.index.json")!
            ))
            for i in 1...shardCount {
                let name = String(format: "model-%05d-of-%05d.safetensors", i, shardCount)
                files.append(ModelFile(
                    path: name,
                    bytes: perShard,
                    sha256: "",
                    url: URL(string: "\(base)/\(name)")!
                ))
            }
        }
        return files
    }

    private static func mlxEmbedderFiles(base: String, approximateBytes: Int64) -> [ModelFile] {
        let metaBytes: Int64 = 500_000
        return [
            ModelFile(path: "config.json", bytes: 2_000, sha256: "",
                      url: URL(string: "\(base)/config.json")!),
            ModelFile(path: "tokenizer.json", bytes: 700_000, sha256: "",
                      url: URL(string: "\(base)/tokenizer.json")!),
            ModelFile(path: "tokenizer_config.json", bytes: 2_000, sha256: "",
                      url: URL(string: "\(base)/tokenizer_config.json")!),
            ModelFile(path: "special_tokens_map.json", bytes: 1_000, sha256: "",
                      url: URL(string: "\(base)/special_tokens_map.json")!),
            ModelFile(path: "model.safetensors",
                      bytes: max(0, approximateBytes - metaBytes),
                      sha256: "",
                      url: URL(string: "\(base)/model.safetensors")!),
        ]
    }
}
