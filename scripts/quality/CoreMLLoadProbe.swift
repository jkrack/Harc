import CoreML
import Foundation
import Darwin

/// Read-only model-loading diagnostic. It never predicts or processes audio.
@main
struct CoreMLLoadProbe {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let policy = CommandLine.arguments[2]
        let config = MLModelConfiguration()
        switch policy {
        case "cpu": config.computeUnits = .cpuOnly
        case "ane": config.computeUnits = .cpuAndNeuralEngine
        default: exit(2)
        }
        func mark(_ message: String) {
            fflush(nil)
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        }
        mark("BEGIN load-only \(url.lastPathComponent) policy=\(policy)")
        do {
            let start = Date()
            let model = try MLModel(contentsOf: url, configuration: config)
            mark("END load-only seconds=\(Date().timeIntervalSince(start))")
            for (name, feature) in model.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
                mark("INPUT \(name) shape=\(feature.multiArrayConstraint?.shape.description ?? "not-array")")
            }
            withExtendedLifetime(model) {}
        } catch {
            mark("FAILED \(error)")
            exit(1)
        }
        mark("DONE no prediction performed")
    }
}
