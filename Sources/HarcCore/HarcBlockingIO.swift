import Foundation

/// Suspend an async caller while kernel-blocking I/O runs on a dedicated thread.
/// Detached Swift tasks still use the cooperative executor and cannot provide
/// this isolation when the operation's peer needs async work on that executor.
package enum HarcBlockingIO {
    package static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(with: Result { try operation() })
            }.start()
        }
    }
}
