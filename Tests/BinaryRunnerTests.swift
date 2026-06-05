import Foundation
import Testing
import ASTRACore

@Suite("ProcessBinaryRunner")
struct ProcessBinaryRunnerTests {
    @Test("RunResult exposes exit contract fields")
    func runResultExitContractFields() {
        let result = RunResult.exited(code: 0, stdout: "ok", stderr: "")

        #expect(result.outcome == .exited(code: 0))
        #expect(result.exitCode == 0)
        #expect(result.stdout == "ok")
        #expect(result.stderr == "")
        #expect(result.launchError == nil)
        #expect(result.timedOut == false)
        #expect(result.cancelled == false)
        #expect(result.elapsedTime == 0)
        #expect(result.isSuccess == true)
    }

    @Test("Successful process records elapsed time")
    func successfulProcessRecordsElapsedTime() async {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", "printf ok"],
            timeout: 3,
            environment: nil
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "ok")
        #expect(result.elapsedTime >= 0)
    }

    @Test("Process runner honors current directory")
    func processRunnerHonorsCurrentDirectory() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-process-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "cwd marker".write(
            to: directory.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", "cat marker.txt"],
            timeout: 3,
            environment: nil,
            currentDirectory: directory.path
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "cwd marker")
    }

    @Test("Launch failure is classified without an exit code")
    func launchFailureClassification() async {
        let result = await ProcessBinaryRunner().run(
            path: "/nonexistent/astra-test-binary",
            args: [],
            timeout: 1,
            environment: nil
        )

        #expect(result.exitCode == nil)
        #expect(result.launchError?.isEmpty == false)
        #expect(result.timedOut == false)
        #expect(result.cancelled == false)
        #expect(result.isSuccess == false)
        guard case .launchFailed = result.outcome else {
            Issue.record("Expected launch failure, got \(result.outcome)")
            return
        }
    }

    @Test("Timeout is classified without an exit code")
    func timeoutClassification() async {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", "printf out; printf err >&2; sleep 5"],
            timeout: 0.1,
            environment: nil
        )

        #expect(result.exitCode == nil)
        #expect(result.launchError == nil)
        #expect(result.timedOut == true)
        #expect(result.cancelled == false)
        #expect(result.elapsedTime > 0)
        #expect(result.isSuccess == false)
        #expect(result.stdout.contains("out"))
        #expect(result.stderr.contains("err"))
        #expect(result.outcome == .timedOut)
    }

    @Test("Caller cancellation is classified separately from timeout")
    func cancellationClassification() async {
        let task = Task {
            await ProcessBinaryRunner().run(
                path: "/bin/sh",
                args: ["-c", "sleep 5"],
                timeout: 30,
                environment: nil
            )
        }

        task.cancel()
        let result = await task.value

        #expect(result.exitCode == nil)
        #expect(result.launchError == nil)
        #expect(result.timedOut == false)
        #expect(result.cancelled == true)
        #expect(result.isSuccess == false)
        #expect(result.outcome == .cancelled)
    }
}
