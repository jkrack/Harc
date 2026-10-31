import Testing

/// Serializes tests that exercise process-wide Apple system resources.
///
/// Swift Testing's built-in `.serialized` trait orders a suite's own tests but
/// does not order that suite relative to unrelated suites. Harc's real
/// Security.framework fixtures and Network.framework listeners can therefore
/// overlap across test targets in the shared package test process. Apply this
/// recursive trait only to suites that own those resources.
public struct ProcessWideSystemResourceTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public init() {}

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await ProcessWideSystemResourceLock.shared.acquire()
        do {
            try await function()
            await ProcessWideSystemResourceLock.shared.release()
        } catch {
            await ProcessWideSystemResourceLock.shared.release()
            throw error
        }
    }
}

public extension Trait where Self == ProcessWideSystemResourceTrait {
    static var processWideSystemResource: Self { Self() }
}

private actor ProcessWideSystemResourceLock {
    static let shared = ProcessWideSystemResourceLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
