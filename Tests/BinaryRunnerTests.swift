import Foundation
import Testing
import ASTRACore

@Suite("ProcessBinaryRunner")
struct ProcessBinaryRunnerTests {
    @Test("Hardened process executor provides synchronous PATH lookup and stdin")
    func hardenedProcessExecutorProvidesSynchronousPathLookupAndStdin() {
        let result = HardenedProcessExecutor().runSynchronously(
            HardenedProcessRequest(
                executable: "cat",
                standardInput: Data("mail input".utf8),
                timeout: 3
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "mail input")
        #expect(result.timedOut == false)
        #expect(result.launchError == nil)
    }

    @Test("Hardened process executor classifies synchronous timeouts")
    func hardenedProcessExecutorClassifiesSynchronousTimeouts() {
        let result = HardenedProcessExecutor().runSynchronously(
            HardenedProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "printf started; sleep 5"],
                timeout: 0.1
            )
        )

        #expect(result.exitCode == nil)
        #expect(result.timedOut == true)
        #expect(result.stdout.contains("started"))
        #expect(result.outcome == .timedOut)
    }

    @Test("Hardened process executor caps captured output and reports truncation")
    func hardenedProcessExecutorCapsOutputAndReportsTruncation() {
        let result = HardenedProcessExecutor().runSynchronously(
            HardenedProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "printf 1234567890"],
                timeout: 3,
                maximumOutputBytes: 4
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "1234")
        #expect(result.stdoutTruncated)
        #expect(!result.stderrTruncated)
    }

    @Test("Hardened process executor preserves the valid UTF-8 prefix when truncation lands mid-character")
    func hardenedProcessExecutorPreservesValidPrefixOnMidCharacterTruncation() {
        // \346\227\245 is the 3-byte UTF-8 encoding of 日 (U+65E5); capping at
        // 4 bytes keeps "AB" plus only the first 2 of those 3 bytes, landing
        // mid multi-byte character. A strict UTF-8 decode of that buffer
        // fails wholesale and used to return "", losing "AB" too.
        let result = HardenedProcessExecutor().runSynchronously(
            HardenedProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'AB\\346\\227\\245'"],
                timeout: 3,
                maximumOutputBytes: 4
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.stdoutTruncated)
        #expect(result.stdout.hasPrefix("AB"))
    }

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

    @Test("Stdin payload is delivered and closed so the child sees EOF")
    func stdinPayloadIsDeliveredWithEOF() async {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/cat",
            args: [],
            timeout: 3,
            environment: nil,
            stdin: Data("ping over stdin".utf8)
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "ping over stdin")
    }

    @Test("Nil stdin still terminates stdin-reading children")
    func nilStdinTerminatesStdinReaders() async {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/cat",
            args: [],
            timeout: 3,
            environment: nil
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
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

    @Test("Process group timeout terminates descendant processes")
    func processGroupTimeoutTerminatesDescendants() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-process-group-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("child.pid")
        let script = """
        (trap '' TERM; while true; do sleep 1; done) &
        printf "%s" "$!" > "\(pidFile.path)"
        wait
        """

        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", script],
            timeout: 0.1,
            environment: nil,
            currentDirectory: nil,
            terminateProcessGroup: true
        )

        #expect(result.outcome == .timedOut)
        try await Task.sleep(nanoseconds: 800_000_000)
        let childPID = try Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let childPID else {
            Issue.record("Expected child PID to be captured")
            return
        }
        if kill(childPID, 0) == 0 {
            kill(childPID, SIGKILL)
            Issue.record("Timed-out process group left descendant process \(childPID) alive")
        }
    }

    @Test("Process group mode is active before executable code runs")
    func processGroupModeIsActiveBeforeExecutableCodeRuns() async throws {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", "printf '%s %s' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\""],
            timeout: 3,
            environment: nil,
            currentDirectory: nil,
            terminateProcessGroup: true
        )

        #expect(result.exitCode == 0)
        let fields = result.stdout.split(separator: " ")
        let pid = fields.first.flatMap { Int32($0) }
        let processGroup = fields.dropFirst().first.flatMap { Int32($0) }
        #expect(pid != nil)
        #expect(processGroup != nil)
        #expect(processGroup == pid)
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
