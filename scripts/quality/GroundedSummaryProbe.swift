import Foundation
import HarcSummarize
import MLX
struct Line: Codable { let speaker: String; let text: String }
struct Sample: Codable { let id: String; let lines: [Line]; let actors: [String] }
struct InputLine: Codable { let utterance: Int; let speaker: String; let text: String }
struct Result: Codable { let id: String; let raw: String; let stopReason: String; let seconds: Double; let generatedTokens: Int }
final class Completion: @unchecked Sendable {
 let lock = NSLock()
 var value = "missing"
 var tokens = 0
 func observe(_ stats: GenerationStats) {
  guard stats.isFinal else { return }
  lock.lock(); defer { lock.unlock() }
  tokens = stats.generatedTokens
  switch stats.stopReason {
  case .complete: value = "complete"
  case .cancelled: value = "cancelled"
  case .outputLimit: value = "outputLimit"
  case nil: value = "missing"
  }
 }
 func tokenCount() -> Int { lock.lock(); defer { lock.unlock() }; return tokens }
 func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
@main struct Grounding {
 static func main() async throws {
  let a = CommandLine.arguments
  Memory.cacheLimit = 128 * 1024 * 1024
  let cases = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath:a[2])))
  let template = try String(contentsOfFile:a[3], encoding:.utf8)
  let model = try await SummarizerService.defaultLoader(URL(fileURLWithPath:a[1]))
  var results: [Result] = []
  for sample in cases {
   let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
   let input = String(decoding:try encoder.encode(sample.lines.enumerated().map { InputLine(utterance:$0.offset+1,speaker:$0.element.speaker,text:$0.element.text) }),as:UTF8.self)
   let completion = Completion(); let start = Date()
   let raw = try await model.generateSummary(promptBody:template.replacingOccurrences(of:"{TRANSCRIPT}",with:input),maxTokens:2048,onStats:{ completion.observe($0) })
   results.append(.init(id:sample.id,raw:raw,stopReason:completion.read(),seconds:Date().timeIntervalSince(start),generatedTokens:completion.tokenCount()))
   try encoder.encode(results).write(to:URL(fileURLWithPath:a[4]),options:.atomic)
   print("\(sample.id): \(completion.read())");fflush(stdout)
  }
 }
}
