import Foundation

/// Generation throughput snapshot. Interim values (`isFinal == false`) are
/// derived from streamed chunk counts and wall-clock time; the final value
/// carries the authoritative numbers from MLX's completion info.
public struct GenerationStats: Sendable, Equatable {
    public let generatedTokens: Int
    public let tokensPerSecond: Double
    public let isFinal: Bool

    public init(generatedTokens: Int, tokensPerSecond: Double, isFinal: Bool) {
        self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond
        self.isFinal = isFinal
    }
}

/// UserDefaults-backed record of each model's measured generation speed on
/// this machine — an exponential moving average so one thermally-throttled
/// run doesn't overwrite a stable baseline. Read by Settings → Models to
/// show "~N tok/s on this Mac" instead of static estimates.
public enum MeasuredModelSpeed {
    static let defaultsKey = "harc.model.measuredTokensPerSecond"
    private static let smoothing = 0.3

    public static func record(modelID: String, tokensPerSecond: Double) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        var table = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        if let prior = table[modelID] {
            table[modelID] = prior * (1 - smoothing) + tokensPerSecond * smoothing
        } else {
            table[modelID] = tokensPerSecond
        }
        UserDefaults.standard.set(table, forKey: defaultsKey)
    }

    public static func tokensPerSecond(for modelID: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double])?[modelID]
    }
}
