import Foundation

/// Inert groundwork. No public constructor until installed-config qualification
/// binds a model identity, config digest and verified context limit.
public struct EvidenceGenerationBudget: Sendable {
    let contextLimit: Int
    let outputReserve: Int

    init(contextLimit: Int, outputReserve: Int) throws {
        guard contextLimit > 0, contextLimit <= 32_768,
              outputReserve > 0, outputReserve <= 1_024,
              outputReserve < contextLimit else { throw EvidenceGenerationError.invalidBudget }
        self.contextLimit = contextLimit
        self.outputReserve = outputReserve
    }

    func validate(promptTokens: Int) throws {
        guard promptTokens > 0, promptTokens <= contextLimit - outputReserve else {
            throw EvidenceGenerationError.contextExceeded
        }
    }
}

public enum EvidenceGenerationError: Error, Equatable {
    case unsupported, invalidBudget, contextExceeded, invalidCompletion, outputExceeded, modelNotResident, unrelatedResident
}

/// Collector accepts only one authoritative normal completion, no tools or
/// content after completion. It never logs or repairs model content.
struct EvidenceGenerationCollector {
    private(set) var text = ""
    private var completed = false

    mutating func append(_ fragment: String) throws {
        guard !completed else { throw EvidenceGenerationError.invalidCompletion }
        guard fragment.utf8.count <= 4_096 - text.utf8.count else {
            throw EvidenceGenerationError.outputExceeded
        }
        text += fragment
    }

    mutating func complete(normally: Bool) throws {
        guard normally, !completed else { throw EvidenceGenerationError.invalidCompletion }
        completed = true
    }

    func finish() throws -> String {
        guard completed else { throw EvidenceGenerationError.invalidCompletion }
        return text
    }
}

/// The model task may outlive stream consumption. Keep the service's operation
/// ownership until all producer cleanup has finished, on success AND error.
func withEvidenceProducerCleanup<T: Sendable>(
    _ producer: Task<Void, Never>, operation: () async throws -> T
) async throws -> T {
    try await withTaskCancellationHandler {
        do {
            let result = try await operation()
            await producer.value
            try Task.checkCancellation()
            return result
        } catch {
            producer.cancel()
            await producer.value
            throw error
        }
    } onCancel: {
        producer.cancel()
    }
}

/// Role separation is a prompt boundary, never a semantic-safety guarantee.
/// Pure construction seam shared by production and synthetic boundary tests.
enum EvidenceRoleMessages {
    static func legacy(_ body: String) throws -> [[String: String]] {
        guard body.utf8.count <= 40_960 else { throw EvidenceGenerationError.contextExceeded }
        return [["role": "user", "content": body]]
    }
    static func separated(systemPrompt: String, sourceJSON: String) throws -> [[String: String]] {
        let policyBytes = systemPrompt.utf8.count
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              policyBytes <= 8_192, sourceJSON.utf8.count <= 40_960 - policyBytes else {
            throw EvidenceGenerationError.contextExceeded
        }
        return [["role": "system", "content": systemPrompt], ["role": "user", "content": sourceJSON]]
    }
}
