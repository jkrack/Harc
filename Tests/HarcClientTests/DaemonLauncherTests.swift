import Foundation
import Testing
@testable import HarcClient

@Suite("DaemonLauncher lifecycle", .timeLimit(.minutes(1)))
struct DaemonLauncherTests {
    private func fixture(script: String) throws -> (URL, DaemonLauncher) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-launcher-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("fake-daemon")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (root, DaemonLauncher(binaryURL: binary,
                                    socketPath: root.appendingPathComponent("socket").path,
                                    logURL: root.appendingPathComponent("launch.log")))
    }

    private func waitForLaunch(in root: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: root.appendingPathComponent("launch.log"), encoding: .utf8),
               text.contains("launched") { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("fake daemon did not start")
    }

    @Test("concurrent waiters share one child; cancellation and stop invalidate waits")
    func sharedLaunch() async throws {
        let (root, launcher) = try fixture(script: "echo launched\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await launcher.ensureRunning() }
        try await waitForLaunch(in: root)
        let others = (0..<6).map { _ in Task { try await launcher.ensureRunning() } }
        // Allow every waiter to enter the polling phase while no socket exists.
        try await Task.sleep(for: .milliseconds(400))
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("cancelled startup returned success")
        } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        let launches = try String(contentsOf: root.appendingPathComponent("launch.log"), encoding: .utf8)
        #expect(launches.split(separator: "\n").count == 1)
        await launcher.stop()
        for task in others {
            do {
                _ = try await task.value
                Issue.record("stopped startup returned success")
            } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("already cancelled startup never launches a child")
    func cancelledBeforeLaunch() async throws {
        let (root, launcher) = try fixture(script: "echo launched\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await launcher.ensureRunning()
        }
        do {
            _ = try await task.value
            Issue.record("cancelled startup returned success")
        } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("launch.log").path))
        await launcher.stop()
    }

    @Test("early child exit fails promptly and a later request can retry")
    func earlyExit() async throws {
        let (root, launcher) = try fixture(script: "echo launched\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let began = ContinuousClock.now
        for _ in 0..<2 {
            do {
                _ = try await launcher.ensureRunning()
                Issue.record("exited child returned success")
            } catch {
                #expect(String(describing: error).contains("status 7"))
            }
        }
        #expect(began.duration(to: .now) < .seconds(5))
        let launches = try String(contentsOf: root.appendingPathComponent("launch.log"), encoding: .utf8)
        #expect(launches.split(separator: "\n").count == 2)
        await launcher.stop()
    }
}
