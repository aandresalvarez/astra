import Foundation
import Testing
import ASTRACore

/// Budget for the tests whose subject is *what* the runner does, not how fast
/// it does it. It is a hang breaker, not a latency assertion: a runner that
/// never writes the stdin payload, never closes the write end, or never reaps
/// the child leaves `/bin/cat` blocked forever, and something has to end that.
///
/// It has to sit far above anything the machine can plausibly cost us. At 3
/// seconds it did not: a full `swift test` run on 2026-09-04 was slow enough
/// spawning `/bin/cat` that the stdin test's own budget expired and it reported
/// `exitCode == nil`, while the same test passed in isolation in under a
/// second. Suites in this binary have been measured at ~70 s of wall clock
/// under that contention, so any budget in the same order as normal execution
/// is measuring how busy the machine was rather than whether the runner is
/// correct. A genuine hang still fails these tests — just slowly.
///
/// Timeout *classification* is asserted separately, by the tests that pass a
/// deliberately short budget against a deliberately long-running child. Those
/// stay honest under the same load by construction: contention can only push
/// the child further past its deadline, never under it. Don't fold the two
/// kinds of budget back together.
private let hangBreakerTimeout: TimeInterval = 120

@Suite("ProcessBinaryRunner")
struct ProcessBinaryRunnerTests {
    @Test("Hardened process executor provides synchronous PATH lookup and stdin")
    func hardenedProcessExecutorProvidesSynchronousPathLookupAndStdin() {
        let result = HardenedProcessExecutor().runSynchronously(
            HardenedProcessRequest(
                executable: "cat",
                standardInput: Data("mail input".utf8),
                timeout: hangBreakerTimeout
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
                timeout: hangBreakerTimeout,
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
                timeout: hangBreakerTimeout,
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
            timeout: hangBreakerTimeout,
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
            timeout: hangBreakerTimeout,
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
            timeout: hangBreakerTimeout,
            environment: nil,
            stdin: Data("ping over stdin".utf8)
        )

        // `cat` exits only once its stdin is closed, so the exit itself is half
        // the assertion: a runner that writes the payload but leaves the write
        // end open reads back as a timeout, not as wrong output. Asserted on
        // `outcome` rather than `exitCode` so that failure says `.timedOut`
        // instead of `nil`, which reads like the child never ran.
        #expect(
            result.outcome == .exited(code: 0),
            "cat did not exit, so stdin was never closed: \(result.outcome)"
        )
        #expect(result.stdout == "ping over stdin")
    }

    @Test("Nil stdin still terminates stdin-reading children")
    func nilStdinTerminatesStdinReaders() async {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/cat",
            args: [],
            timeout: hangBreakerTimeout,
            environment: nil
        )

        // No payload means the child should get /dev/null, already at EOF. The
        // regression is a runner that hands it an open pipe nobody closes, and
        // that shows up here as a timeout rather than as unexpected output.
        #expect(
            result.outcome == .exited(code: 0),
            "cat did not exit, so its stdin was left open: \(result.outcome)"
        )
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

        // `run` returns the moment the timeout is stamped, before the group has
        // even been signalled: the runner then sends SIGTERM, waits 500 ms for
        // the grace period, and SIGKILLs. Waiting that out with one fixed sleep
        // measured how busy the machine was, so poll for the descendant to go
        // away instead — same reasoning as `hangBreakerTimeout` above, and the
        // poll floor in `waitUntil` covers a starved cooperative pool that has
        // not yet run the runner's own kill task.
        guard let childPID = await waitForValue({ readPID(from: pidFile) }) else {
            Issue.record("Expected child PID to be captured")
            return
        }
        let descendantIsGone = await waitUntil { !isAlive(childPID) }
        if !descendantIsGone {
            kill(childPID, SIGKILL)
            Issue.record("Timed-out process group left descendant process \(childPID) alive")
        }
    }

    @Test("Process group mode is active before executable code runs")
    func processGroupModeIsActiveBeforeExecutableCodeRuns() async throws {
        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", "printf '%s %s' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\""],
            timeout: hangBreakerTimeout,
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

    // MARK: - Waiting

    /// Polls rather than sleeping a fixed amount, so a slow machine waits
    /// longer instead of failing.
    ///
    /// Both bounds have to be exhausted before this gives up: the deadline
    /// stops a genuinely stuck runner from hanging the suite, and the poll
    /// floor stops a starved one from being mistaken for it. A satisfied
    /// predicate still returns on the next turn, so neither bound slows the
    /// happy path.
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) async -> Bool {
        await waitForValue(timeout: timeout) { () -> Bool? in predicate() ? true : nil } ?? false
    }

    /// `waitUntil` for a value that does not exist yet — here, a PID file the
    /// child may not have written by the time the parent was killed.
    private func waitForValue<Value>(
        timeout: TimeInterval = 30,
        _ produce: () -> Value?
    ) async -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        var value = produce()
        while value == nil, polls < 40 || Date() < deadline {
            polls += 1
            try? await Task.sleep(nanoseconds: 25_000_000)
            value = produce()
        }
        return value
    }

    private func readPID(from file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` fails with EPERM for a process that exists but is not
    /// ours to signal, which must not be read as "it exited."
    private func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
