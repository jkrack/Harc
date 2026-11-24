# Selected evidence in complete source

This isolated slice is based on PR227, not PR228. It adds no production entry point, model call, Store write, confirmation, automatic assignment, source export or new inference capability.

The existing full-context preview now emphasizes the selected excerpt inside the complete source using bold and underline. Every surrounding byte remains present, including preceding qualifications and later corrections. Nothing auto-scrolls or collapses context. Static copy says selection is not verified meaning. The detached excerpt remains labeled partial context.

The presentation-only partition accepts only nonempty exact UTF-8 selections with ordered, in-range offsets at full Character boundaries. Splitting combining sequences, emoji ZWJ sequences, flags or CRLF is rejected even if a scalar slice could decode. It verifies reconstruction equals all original bytes, without canonical normalization or lossy decoding. Any mismatch renders the entire original source without emphasis.

Each segment uses literal Text, not Markdown, URLs or actions. The result is one combined Text with the complete original source as its accessibility label, retaining the existing source identifier. Actual assistive-technology reading order and emphasis behavior still require qualification; source-level grouping is not a VoiceOver pass.

Validation is synthetic only. No accessibility collection or raw tree publication is used in this slice. Focused tests cover beginning/end/repeated quote offsets, Unicode, malformed offsets and byte mismatch, with existing inert panel layout and controller invalidation tests. Full CI and visual/VoiceOver qualification remain separate gates.

The focused run completed with exit zero: 13 tests in three suites passed (including parameterized Unicode cases and both appearance layouts). No screenshot or accessibility capture was performed. These tests do not prove rendered emphasis or actual VoiceOver reading order.
