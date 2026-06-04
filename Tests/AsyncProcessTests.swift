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
        process.arguments = ["-c", "sleep 10 & wait"]

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

        #expect(elapsed < 8, "Timed-out wrapper process did not return promptly: \(elapsed)s")
        #expect(result.exitCode == -1)
        #expect(result.stderr.contains("timed out"))
    }
}
