import Foundation
import HarcStore
import HarcExport

/// A complete source-row identity invalidates same-selection transcript changes.
/// This cache is deliberately independent of editable transcript state.
struct RecordingSpeakerMetadata: Sendable {
    let recording: Recording
    let indices: [Int]

    static func load(recording: Recording) async -> Self {
        guard !Task.isCancelled else { return Self(recording: recording, indices: []) }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let input = ExportInputBuilder.build(from: recording)
            try Task.checkCancellation()
            return Self(recording: recording, indices: Array(Set(input.segments.compactMap(\.speaker))).sorted())
        }
        return await withTaskCancellationHandler {
            (try? await worker.value) ?? Self(recording: recording, indices: [])
        } onCancel: {
            worker.cancel()
        }
    }
}
