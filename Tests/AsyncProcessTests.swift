import Testing
import Foundation
@testable import ASTRA

@Suite("AsyncProcessRunner")
struct AsyncProcessRunnerTests {

    @Test("runAsync returns stdout and exit code")
    func basicRun() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["hello world"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: nil)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello world")
    }

    @Test("runAsync captures stderr")
    func capturesStderr() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo err >&2; exit 1"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        #expect(result.exitCode == 1)
        #expect(result.stderr == "err")
    }

    @Test("runAsync returns error for invalid executable")
    func invalidExecutable() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/binary")

        let result = await AsyncProcessRunner.run(process, stdout: Pipe(), stderr: Pipe())
        #expect(result.exitCode == -1)
        #expect(!result.stderr.isEmpty)
    }

    @Test("runAsync does not block the cooperative thread pool")
    func nonBlocking() async {
        // Launch a process that sleeps, while also doing work concurrently.
        // If waitUntilExit() were used, the concurrent task wouldn't start
        // until the sleep finishes (on the same thread).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        async let processResult = AsyncProcessRunner.run(process, stdout: pipe, stderr: nil)
        async let concurrentTaskRan: Bool = {
            await Task.yield()
            return true
        }()

        let didRunConcurrently = await concurrentTaskRan
        let result = await processResult
        #expect(didRunConcurrently)
        #expect(result.exitCode == 0)
    }

    @Test("runAsync timeout terminates wrapper child processes")
    func timeoutTerminatesWrapperChildProcesses() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-async-timeout-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Only a child that existed when the timeout fired is one it must
        // kill, and no timeout guarantees /bin/sh gets that far under
        // full-suite load: a SIGTERM before the fork leaves nothing to check,
        // and a fork after terminateProcessTree's one child scan escapes it.
        // The timer can't fire before start + timeout, so a pid recorded
        // after that proves nothing; such an attempt is retried with double
        // the timeout, and only one that recorded its pid in time is checked.
        for (attempt, timeoutSeconds) in [0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8].enumerated() {
            let attemptRoot = root.appendingPathComponent("attempt-\(attempt)", isDirectory: true)
            try FileManager.default.createDirectory(at: attemptRoot, withIntermediateDirectories: true)
            let childPIDFile = attemptRoot.appendingPathComponent("child.pid")
            // Written only by a child that outlived its sleep, so a run that
            // returned because the child finished on its own still fails.
            let finishedMarker = attemptRoot.appendingPathComponent("child-finished")

            // Process makes the wrapper a group leader and terminate() signals
            // the whole group, so a child left in it dies with or without the
            // descendant walk. `set -m` gives the child its own group, like a
            // provider helper that detaches, so only the walk can reach it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                set -m
                ( sleep 30 && : > '\(finishedMarker.path)' ) &
                printf '%s' "$!" > '\(childPIDFile.path)'
                wait
                """]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let start = Date()
            let result = await AsyncProcessRunner.run(
                process,
                stdout: stdoutPipe,
                stderr: stderrPipe,
                timeoutSeconds: timeoutSeconds
            )

            #expect(result.exitCode == -1)
            #expect(result.stderr.contains("timed out"))
            guard let childPID = recordedPID(at: childPIDFile),
                  let recordedAt = modificationDate(of: childPIDFile),
                  recordedAt < start.addingTimeInterval(timeoutSeconds) else {
                continue
            }
            #expect(!processIsRunning(childPID),
                    "Timeout returned while wrapper child pid \(childPID) was still alive")
            #expect(!FileManager.default.fileExists(atPath: finishedMarker.path),
                    "Timeout returned only after the wrapper child finished on its own")
            return
        }
        Issue.record("The wrapper never recorded its child before the timeout, even at 12.8s")
    }

    private func recordedPID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
