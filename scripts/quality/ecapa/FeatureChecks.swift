import Foundation

@main struct FeatureChecks {
    static func main() async throws {
        let features = ECAPAFeatures()
        var checks = 0
        for count in [0, 31999, 480001] {
            do {
                _ = try features.extract([Float](repeating: 0, count: count))
                fatalError("Accepted unsupported frame count")
            } catch ECAPAFeatures.Failure.invalidAudio { checks += 1 }
        }
        for value in [Float.nan, Float.infinity] {
            var samples = [Float](repeating: 0, count: 32000)
            samples[16000] = value
            do {
                _ = try features.extract(samples)
                fatalError("Accepted nonfinite PCM")
            } catch ECAPAFeatures.Failure.invalidAudio { checks += 1 }
        }
        for count in [32000, 480000] {
            let output = try features.extract([Float](repeating: 0, count: count))
            precondition(output.count == (count / 160 + 1) * 80)
            precondition(output.allSatisfy { $0 == -100 })
            checks += 1
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try features.extract([Float](repeating: 0, count: 32000))
        }
        do {
            _ = try await task.value
            fatalError("Ignored cancellation")
        } catch is CancellationError { checks += 1 }
        print("Passed \(checks) native feature boundary checks")
    }
}
