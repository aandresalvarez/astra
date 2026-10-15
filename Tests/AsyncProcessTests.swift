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
    func timeoutTerminatesWrapperChildProcesses() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & wait"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let start = Date()
        let result = await AsyncProcessRunner.run(
            process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            timeoutSeconds: 0.2
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 15, "Timed-out wrapper process did not return promptly: \(elapsed)s")
        #expect(result.exitCode == -1)
        #expect(result.stderr.contains("timed out"))
    }

    @Test("runAsync timeout terminates children forked while the tree is torn down")
    func timeoutTerminatesChildrenForkedDuringTeardown() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-async-forking-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The wrapper forks without pause until it dies, so it is still
        // forking while terminateProcessTree lists and signals its children,
        // and a child forked after that list is one the teardown must still
        // catch. `set -m` gives every child its own process group, out of
        // reach of terminate()'s group signal. Each child kills the one
        // before it, so no more than two are alive however long the loop runs.
        for (attempt, timeoutSeconds) in [0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8].enumerated() {
            let pidFile = root.appendingPathComponent("children-\(attempt).pid")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                set -m
                previous=
                while :; do
                    sleep 30 &
                    echo "$!" >> '\(pidFile.path)'
                    [ -n "$previous" ] && kill "$previous"
                    previous=$!
                done
                """]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let result = await AsyncProcessRunner.run(
                process,
                stdout: nil,
                stderr: nil,
                timeoutSeconds: timeoutSeconds
            )
            let children = recordedPIDs(at: pidFile)
            defer {
                for child in children where processIsRunning(child) {
                    kill(child, SIGKILL)
                }
            }

            #expect(result.exitCode == -1)
            #expect(result.stderr.contains("timed out"))
            // The timer fired before the shell got to its first fork.
            guard !children.isEmpty else { continue }

            // A child dies of its SIGTERM only once it next runs, so each gets
            // a number of polls to exit; an escaped `sleep 30` outlives them all.
            var survivors = children
            for _ in 0..<200 {
                survivors = survivors.filter(processIsRunning)
                if survivors.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(survivors.isEmpty, """
                Timeout returned while \(survivors.count) of \(children.count) forked children \
                were still alive: \(survivors.prefix(5))
                """)
            return
        }
        Issue.record("The wrapper never forked a child before the timeout, even at 12.8s")
    }

    private func recordedPIDs(at url: URL) -> [pid_t] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}
