import Foundation

/// Turns a transcript edit into vocabulary suggestions (#101): when the user
/// fixes a mistranscribed name in place ("Neil" → "Neal"), the diff is a
/// standing correction the STT pipeline should learn — offered, never
/// auto-added.
public enum VocabularyCorrectionDetector {

    public struct Candidate: Equatable, Hashable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Word-level diff of old→new, filtered down to proper-noun-ish 1:1
    /// substitutions. Bails (returns []) when the changed region exceeds
    /// `maxWindow` tokens — a rewrite that large isn't a correction, and
    /// LCS over an hour-long transcript would be wasted work anyway.
    public static func detect(
        old: String,
        new: String,
        maxWindow: Int = 400
    ) -> [Candidate] {
        guard old != new else { return [] }
        let oldTokens = old.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newTokens = new.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // Trim the identical prefix/suffix — edits are localized, and this
        // keeps the LCS window tiny for the common case.
        var start = 0
        while start < oldTokens.count, start < newTokens.count,
              oldTokens[start] == newTokens[start] {
            start += 1
        }
        var oldEnd = oldTokens.count
        var newEnd = newTokens.count
        while oldEnd > start, newEnd > start, oldTokens[oldEnd - 1] == newTokens[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        let oldMid = Array(oldTokens[start..<oldEnd])
        let newMid = Array(newTokens[start..<newEnd])
        guard !oldMid.isEmpty, !newMid.isEmpty,
              oldMid.count <= maxWindow, newMid.count <= maxWindow else { return [] }

        var candidates: [Candidate] = []
        for (a, b) in alignedSubstitutions(oldMid, newMid) where isCorrectionShaped(from: a, to: b) {
            let candidate = Candidate(
                from: trimPunctuation(a),
                to: trimPunctuation(b)
            )
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // MARK: - Alignment

    /// 1:1 token substitutions from an LCS alignment: tokens that replaced
    /// each other between shared anchors. Insertions/deletions don't pair.
    static func alignedSubstitutions(_ a: [String], _ b: [String]) -> [(String, String)] {
        // LCS table (windows are small — trimmed + capped by the caller).
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(String, String)] = []
        var i = 0, j = 0
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        func flushPending() {
            if pendingOld.count == pendingNew.count {
                pairs.append(contentsOf: zip(pendingOld, pendingNew).map { ($0, $1) })
            }
            pendingOld = []
            pendingNew = []
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                flushPending()
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                pendingOld.append(a[i]); i += 1
            } else {
                pendingNew.append(b[j]); j += 1
            }
        }
        pendingOld.append(contentsOf: a[i...])
        pendingNew.append(contentsOf: b[j...])
        flushPending()
        return pairs
    }

    // MARK: - Filters

    /// Correction-shaped: proper-noun-ish and plausibly the same spoken
    /// word. "Neil"→"Neal" qualifies; "he"→"Sarah" is a rewrite, not a
    /// transcription fix.
    static func isCorrectionShaped(from rawFrom: String, to rawTo: String) -> Bool {
        let from = trimPunctuation(rawFrom)
        let to = trimPunctuation(rawTo)
        guard from.count >= 3, to.count >= 2, from != to else { return false }
        guard from.contains(where: { $0.isLetter }), to.contains(where: { $0.isLetter }) else {
            return false
        }
        // Proper-noun-ish: the corrected form (or the original) is
        // capitalized. Lowercase→lowercase edits are prose rewrites.
        let properish = (to.first?.isUppercase ?? false) || (from.first?.isUppercase ?? false)
        guard properish else { return false }
        // Same spoken word, different spelling: small edit distance or a
        // shared stem. A correction replaces sounds, not subjects.
        let lf = from.lowercased(), lt = to.lowercased()
        if lf == lt { return true }  // pure capitalization fix
        let dist = levenshtein(lf, lt)
        let budget = max(2, min(lf.count, lt.count) / 2)
        return dist <= budget || lf.commonPrefix(with: lt).count >= 3
    }

    static func trimPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: .punctuationCharacters)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        guard !aa.isEmpty else { return bb.count }
        guard !bb.isEmpty else { return aa.count }
        var prev = Array(0...bb.count)
        var cur = Array(repeating: 0, count: bb.count + 1)
        for i in 1...aa.count {
            cur[0] = i
            for j in 1...bb.count {
                cur[j] = aa[i - 1] == bb[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[bb.count]
    }
}
