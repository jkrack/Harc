import Foundation

/// Spoken editing commands inside a dictation, applied to the transcribed
/// text BEFORE any mode transform — so they work identically in Raw and
/// LLM modes and never depend on model behavior (#100).
///
/// Safety rule: a command only fires when it stands as its own clause —
/// its first word begins the utterance or follows punctuation, and its
/// last word ends the utterance or carries/precedes punctuation. Spoken
/// commands come out of Parakeet as their own little sentences ("New
/// line." / "Scratch that."), while false-positive phrases sit mid-clause
/// ("a new line of products") and are left untouched.
public enum DictationInlineCommands {

    /// English command set, initial scope: line breaks and scratch-that.
    private enum Command {
        case newline(String)
        case scratch

        static func match(_ first: String, _ second: String) -> Command? {
            switch (first, second) {
            case ("new", "line"):       return .newline("\n")
            case ("new", "paragraph"):  return .newline("\n\n")
            case ("scratch", "that"), ("delete", "that"): return .scratch
            default: return nil
            }
        }
    }

    public static func apply(to text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return text }

        func core(_ token: String) -> String {
            token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        func endsClause(_ token: String) -> Bool {
            guard let last = token.last else { return false }
            return ".!?,;:".contains(last)
        }
        func endsSentence(_ token: String) -> Bool {
            guard let last = token.last else { return false }
            return ".!?".contains(last)
        }

        // Output is a list of tokens; newline commands become explicit "\n"
        // tokens so a later scratch can't reach across a break the user
        // deliberately spoke.
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count,
               let command = Command.match(core(tokens[i]), core(tokens[i + 1])),
               (i + 2 == tokens.count) || endsClause(tokens[i + 1]) {
                switch command {
                case .newline(let brk):
                    // Line breaks additionally require a leading boundary:
                    // "a new line of products" must never break, while a
                    // scratch legitimately follows the flubbed phrase with
                    // no punctuation between ("…works better, scratch that").
                    guard out.last.map({ endsClause($0) || $0.hasPrefix("\n") }) ?? true else {
                        break
                    }
                    out.append(brk)
                    i += 2
                    continue
                case .scratch:
                    // Drop back to the previous *sentence* end or spoken
                    // break — commas belong to the flubbed segment being
                    // erased, so they don't stop the sweep.
                    while let last = out.last, !endsSentence(last), !last.hasPrefix("\n") {
                        out.removeLast()
                    }
                    i += 2
                    continue
                }
            }
            out.append(tokens[i])
            i += 1
        }

        // Rejoin: spaces between words, none around explicit breaks.
        var result = ""
        for token in out {
            if token.hasPrefix("\n") {
                result += token
            } else {
                if !result.isEmpty, !result.hasSuffix("\n") { result += " " }
                result += token
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
