import Foundation

/// Hardcoded, versioned list of shipped models.
///
/// Changing `v1` requires a code change — that's the point. Descriptors name
/// specific pinned revisions from `mlx-community` so a model's weights can't
/// silently change out from under users.
///
/// ## Manifest completeness
///
/// `ModelFile.sha256` must be populated for every downloadable file. Downloads
/// are refused unless the descriptor pins an immutable revision and every file
/// has a SHA256.
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

    /// Descriptors that can be offered as user-installable models today.
    public static func downloadableDescriptors(for task: ModelTask) -> [ModelDescriptor] {
        descriptors(for: task).filter { $0.manifestVerified }
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

    // Verified 2026-05-17 against the HuggingFace API with files_metadata=true.
    private static let gemma4_E2B_IT_4bit = ModelDescriptor(
        id: "gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 · Standard",
        summary: "MoE E2B instruction-tuned, 4-bit MLX. 3.6 GB on disk; ~20–40 s per hour of audio.",
        task: .summarizer,
        tier: .standard,
        repoID: "mlx-community/gemma-4-e2b-it-4bit",
        revision: "99d9a53ff828d365a8ecae538e45f80a08d612cd",
        files: verifiedRepoFiles(
            repo: "mlx-community/gemma-4-e2b-it-4bit",
            revision: "99d9a53ff828d365a8ecae538e45f80a08d612cd",
            entries: [
                ("chat_template.jinja", 16_317, "781d10940fbc44be40064b5d43a056fc486c84ceaa55538226368b57314132bf"),
                ("config.json", 5_996, "6d12c87861fff3871d3a745011b0d852be6513f3ce594ae1e8d643dae9d3b9a8"),
                ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                ("model.safetensors", 3_581_101_896, "e9bea0584546fafb5ff83a1132a6c4662a8498cc6a5bcda52fc6ca562b7bafab"),
                ("model.safetensors.index.json", 230_329, "a8aa7359c747a0d59368dbff9a1029da86bda139ccc0ae1f1e938db75de7d5ce"),
                ("processor_config.json", 902, "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8"),
                ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                ("tokenizer_config.json", 2_095, "90c3a3ba5bf53818383a58e1a776cbcacd2a038d4812eaa373e1522f2d06f3df"),
            ]
        ),
        minRAMGB: 8,
        recommendedRAMGB: 16,
        contextTokens: 32_000,
        manifestVerified: true
    )

    private static let gemma4_E4B_IT_4bit = ModelDescriptor(
        id: "gemma-4-e4b-it-4bit",
        displayName: "Gemma 4 · Quality",
        summary: "Clearly better summaries. 5.25 GB on disk; 40–90 s per hour. 16 GB RAM recommended.",
        task: .summarizer,
        tier: .quality,
        repoID: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "cc3b666c01c20395e0dcebd53854504c7d9821f9",
        files: verifiedRepoFiles(
            repo: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "cc3b666c01c20395e0dcebd53854504c7d9821f9",
            entries: [
                ("chat_template.jinja", 16_317, "781d10940fbc44be40064b5d43a056fc486c84ceaa55538226368b57314132bf"),
                ("config.json", 6_229, "18521c2237729a659a3b821eeb706f088e46518d8698f8e357df7bf7300e7041"),
                ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                ("model.safetensors", 5_217_361_182, "339409bd18494955556e1fde6ccc15faaa9f707b911b74791fe290b9d722beed"),
                ("model.safetensors.index.json", 251_749, "50c54ba1baf793652f8f85fb61cf9bedfafdc2ea7b59f80cf56611c9912fccd0"),
                ("processor_config.json", 902, "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8"),
                ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                ("tokenizer_config.json", 2_095, "90c3a3ba5bf53818383a58e1a776cbcacd2a038d4812eaa373e1522f2d06f3df"),
            ]
        ),
        minRAMGB: 16,
        recommendedRAMGB: 16,
        contextTokens: 32_000,
        manifestVerified: true
    )

    private static let gemma4_26B_A4B_IT_4bit = ModelDescriptor(
        id: "gemma-4-26b-a4b-it-4bit",
        displayName: "Gemma 4 · Max",
        summary: "Highest quality. Runs E4B-speed via MoE. 32 GB+ Apple Silicon recommended.",
        task: .summarizer,
        tier: .max,
        repoID: "mlx-community/gemma-4-26b-a4b-it-4bit",
        revision: "695690b33533b1f8b0395c1d6b4f00dc411353ef",
        files: verifiedRepoFiles(
            repo: "mlx-community/gemma-4-26b-a4b-it-4bit",
            revision: "695690b33533b1f8b0395c1d6b4f00dc411353ef",
            entries: [
                ("chat_template.jinja", 16_448, "85a08664d16d8f3be4416c92427b3ac10df1024ac566cc0b4bc3bab409393f98"),
                ("config.json", 33_381, "a64883e3afd8e8b76e7370ba1b288f6f2dc9a0e071337c9eddb420b747555209"),
                ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                ("model-00001-of-00003.safetensors", 5_275_612_587, "6a6cba167e5c630a69b527b2b095c0da623507511e43c05a57c5527d9b66fa0d"),
                ("model-00002-of-00003.safetensors", 5_296_718_232, "922461e4da8c9e3ae2dc5e4f0ccedf5a0259f1e81d3ebda20b3af39e28118f33"),
                ("model-00003-of-00003.safetensors", 5_036_507_755, "2e92af87837744c385101b71883b4af898be7a6ce03e5babca475899a8268347"),
                ("model.safetensors.index.json", 176_940, "5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80"),
                ("processor_config.json", 627, "50c9cf588f1bda1c93d92ec69b03011bf101cc6867c6415fe5f07f1c87e49e72"),
                ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                ("tokenizer_config.json", 2_095, "90c3a3ba5bf53818383a58e1a776cbcacd2a038d4812eaa373e1522f2d06f3df"),
            ]
        ),
        minRAMGB: 24,
        recommendedRAMGB: 32,
        contextTokens: 32_000,
        manifestVerified: true
    )

    // Verified 2026-05-10 against HuggingFace tree view. This is the MLX
    // 8-bit conversion of BAAI/bge-small-en-v1.5, a 384-dimensional English
    // retrieval embedder small enough to keep resident for note/search work.
    private static let bgeSmallEnV15 = ModelDescriptor(
        id: "bge-small-en-v1.5",
        displayName: "English text embedder",
        summary: "Powers related-meaning search for notes and recordings. 35 MB on disk; 8-bit MLX.",
        task: .textEmbedder,
        tier: .singleton,
        repoID: "mlx-community/bge-small-en-v1.5-8bit",
        revision: "17d007e0406e0e1bb23c046adbbeb01b681824d9",
        files: verifiedRepoFiles(
            repo: "mlx-community/bge-small-en-v1.5-8bit",
            revision: "17d007e0406e0e1bb23c046adbbeb01b681824d9",
            entries: [
                ("config.json", 795, "3d0cb42eb25381e94931c42c8cae3e77b36dd634d6f015bf1c432d0ed7e29f00"),
                ("config_sentence_transformers.json", 124, "940d5f50db195fa6e5e6a4f122c095f77880de259d74b14a65779ed48bdd7c56"),
                ("model.safetensors", 35_540_803, "24921a949e40547f7da454651131636f78ccabc9af521dea28868c9ba6f35ad1"),
                ("model.safetensors.index.json", 26_000, "f9e6dbcf1f81db9913d21718d30ae7aa680e2c266ec4a0420c818a5f38ab21c9"),
                ("modules.json", 349, "84e40c8e006c9b1d6c122e02cba9b02458120b5fb0c87b746c41e0207cf642cf"),
                ("sentence_bert_config.json", 52, "84e39fda68ccbff05bfa723ae9c0e70e23e2ec373b76e0f8c6e71af72a693cbf"),
                ("special_tokens_map.json", 695, "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a"),
                ("tokenizer.json", 711_396, "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"),
                ("tokenizer_config.json", 1_272, "7b082b48a08a0b5c5939d99472e33addce3d96202155e33f7928cecd171186a0"),
                ("vocab.txt", 231_508, "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"),
            ]
        ),
        minRAMGB: 8,
        recommendedRAMGB: 8,
        contextTokens: 512,
        manifestVerified: true
    )

    // ─── File-list helpers ────────────────────────────────────────────────
    //
    private static func verifiedRepoFiles(
        repo: String,
        revision: String,
        entries: [(path: String, bytes: Int64, sha256: String)]
    ) -> [ModelFile] {
        entries.map { entry in
            ModelFile(
                path: entry.path,
                bytes: entry.bytes,
                sha256: entry.sha256,
                url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(entry.path)")!
            )
        }
    }

}
