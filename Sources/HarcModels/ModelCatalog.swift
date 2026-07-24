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
        gemma4_12B_4bit,
        gemma4_26B_A4B_IT_4bit,
        gemma4_31B_IT_4bit,
        qwen35_4B_4bit,
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
    //   - Gemma 4 12B-4bit: pro tier, ~11 GB, 32 GB recommended
    //   - Gemma 4 26B-A4B-it-4bit: max tier, ~15 GB (MoE — 26 B params in
    //     memory, ~4 B activated so compute is E4B-equivalent)
    //   - Gemma 4 31B-it-4bit: ultra tier, ~18.4 GB dense — best summaries
    //     in the catalog but every token pays the full 31 B (~26 tok/s).
    //     Never auto-suggested in onboarding (that filter stops at Quality);
    //     strictly an opt-in from Settings → Models on big-RAM machines.

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

    // Verified 2026-06-06 against the HuggingFace API with blobs=true.
    private static let gemma4_12B_4bit = ModelDescriptor(
        id: "gemma-4-12b-4bit",
        displayName: "Gemma 4 · Pro",
        summary: "Dense 12B unified, 4-bit MLX. 11 GB on disk; stronger multimodal reasoning than Quality. 32 GB RAM recommended.",
        task: .summarizer,
        tier: .pro,
        repoID: "mlx-community/gemma-4-12B-4bit",
        revision: "7d7c99c4d1b1d2ec2b52e2c46821cef2fa22ce0c",
        files: verifiedRepoFiles(
            repo: "mlx-community/gemma-4-12B-4bit",
            revision: "7d7c99c4d1b1d2ec2b52e2c46821cef2fa22ce0c",
            entries: [
                ("config.json", 39_970, "c2be62afb1fd8d64fccb813795b1ea852cf42819f39062141f29bfa81ac8b96f"),
                ("generation_config.json", 233, "02b56bd11e1cd1e363e701a85a2fd7fbaa2992ec3358c1cd7cc44ead7208f505"),
                ("model-00001-of-00003.safetensors", 5_343_482_389, "bbf72072181a7631c561c95fed184c9e754a4645f185a78d3dcf7e82641a92ad"),
                ("model-00002-of-00003.safetensors", 5_315_166_368, "c2333eeb88251c545f472bb6dfa4db1579d72617329267455e49096d7e721de5"),
                ("model-00003-of-00003.safetensors", 329_123_819, "1ec1bf698ee8e0b28f694af1f27ca023b42b84249f20d15f4aaa6a08b1f981f8"),
                ("model.safetensors.index.json", 135_330, "b87c93774de5d13ca9d0e21b045793e42e5df032fb5e7622212524f56f9695f2"),
                ("processor_config.json", 868, "016a1db9c4f41ea0c61919c46855ea5e7c45c6e4ae4bfbedfb5b6bed79a2fe92"),
                ("tokenizer.json", 32_170_070, "12bac982b793c44b03d52a250a9f0d0b666813da566b910c24a6da0695fd11e6"),
                ("tokenizer_config.json", 1_533, "be14c0390e941220070bf5c57589899a9dcd1aef54be6c2c30de0afb226bf2cc"),
            ]
        ),
        minRAMGB: 16,
        recommendedRAMGB: 32,
        contextTokens: 32_000,
        manifestVerified: true
    )

    private static let gemma4_26B_A4B_IT_4bit = ModelDescriptor(
        id: "gemma-4-26b-a4b-it-4bit",
        displayName: "Gemma 4 · Max",
        summary: "Near-Ultra quality at E4B speed via MoE. 32 GB+ Apple Silicon recommended.",
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

    // Verified 2026-07-17 against the HuggingFace API (tree?recursive=true&
    // blobs=true for LFS sha256 + sizes; small git-tracked files downloaded
    // at the pinned revision and sha256'd locally).
    private static let gemma4_31B_IT_4bit = ModelDescriptor(
        id: "gemma-4-31b-it-4bit",
        displayName: "Gemma 4 · Ultra",
        summary: "Highest quality, slowest. Dense 31B — every token pays full price. 18.4 GB on disk; 48 GB RAM recommended.",
        task: .summarizer,
        tier: .ultra,
        repoID: "mlx-community/gemma-4-31b-it-4bit",
        revision: "696d436c404745a59f30e4939a658162b0a9e57f",
        files: verifiedRepoFiles(
            repo: "mlx-community/gemma-4-31b-it-4bit",
            revision: "696d436c404745a59f30e4939a658162b0a9e57f",
            entries: [
                ("chat_template.jinja", 17_466, "36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0"),
                ("config.json", 6_046, "a01be3d45e0eb70ae89cef6d3e823dd44de6ec4dfc41b91dc357f97e457915c0"),
                ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                ("model-00001-of-00004.safetensors", 5_366_617_512, "988e2b1fd41d93b62b8c432f52f632c43b8cb7f86df4b957db36a3cc0dab40ca"),
                ("model-00002-of-00004.safetensors", 5_361_642_573, "a496a96fbd39cd11a9871f91d026013d91069dcac15f89ca861b93976f3857cf"),
                ("model-00003-of-00004.safetensors", 5_367_276_094, "afa555ff0e1bc458c5b08aeef1f4499dce63e2bfb5d3a2aac716e47c0a5672c1"),
                ("model-00004-of-00004.safetensors", 2_316_480_497, "b55567ae065357d047daca926e45619ec0edef994f165356111c95d4d1021587"),
                ("model.safetensors.index.json", 205_370, "a9ca8373aacc37ab9d7f16ff4bbb392c055e1b51b0fec6258cbfc578056c5fef"),
                ("processor_config.json", 1_316, "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"),
                ("tokenizer.json", 32_169_626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                ("tokenizer_config.json", 2_740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656"),
            ]
        ),
        minRAMGB: 32,
        recommendedRAMGB: 48,
        contextTokens: 32_000,
        manifestVerified: true
    )

    // Verified 2026-07-24 against the HuggingFace API (blobs=true for LFS
    // sha256 + sizes; small git-tracked files downloaded at the pinned
    // revision and sha256'd locally). Singleton tier: shown by displayName in
    // pickers, never auto-suggested in onboarding, never preferred by
    // fallback. Added after a head-to-head on the production summary prompt
    // (2026-07-23): best action-item accuracy of the ≤4B models tested,
    // E4B-class speed, smaller download.
    private static let qwen35_4B_4bit = ModelDescriptor(
        id: "qwen-3.5-4b-4bit",
        displayName: "Qwen 3.5 4B",
        summary: "Alternative summarizer. Sharpest action items at this size in our tests; Quality-tier speed. 3 GB on disk; 16 GB RAM recommended.",
        task: .summarizer,
        tier: .singleton,
        repoID: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
        files: verifiedRepoFiles(
            repo: "mlx-community/Qwen3.5-4B-4bit",
            revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            entries: [
                ("chat_template.jinja", 7_756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                ("config.json", 3_366, "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                ("model.safetensors", 3_034_300_695, "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                ("model.safetensors.index.json", 101_944, "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
                ("preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
                ("processor_config.json", 1_300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
                ("tokenizer.json", 19_989_343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                ("tokenizer_config.json", 1_139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
                ("video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
                ("vocab.json", 6_722_759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
            ]
        ),
        minRAMGB: 8,
        recommendedRAMGB: 16,
        contextTokens: 32_000,
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
