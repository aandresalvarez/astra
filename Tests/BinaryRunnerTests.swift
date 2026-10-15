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

/// Budgets, shortest first, for the timeout tests that also check what the
/// child printed. See `timedOutRunPastMarkers`.
///
/// Classification needs no escalation, but output does. A timed-out result
/// carries everything the child wrote before it died, and a 0.1 s budget can
/// expire under contention while the shell is still starting, before it has
/// printed anything. A one-shot assertion on that output measured how busy the
/// machine was (it failed once on 2026-10-12 with stdout empty). A child that
/// has not printed within the last budget means the machine is wedged, and the
/// test fails.
private let outputTimeouts: [TimeInterval] = [0.1, 0.4, 1.6, 6.4, 25.6]

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
    func hardenedProcessExecutorClassifiesSynchronousTimeouts() async throws {
        // `exec` makes the sleeper the child itself, so the timeout kills it
        // instead of orphaning a `sleep` that outlives every budget.
        let result = try await timedOutRunPastMarkers(["printed"]) { timeout, markers in
            HardenedProcessExecutor().runSynchronously(
                HardenedProcessRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", #"printf started; : > "$1/printed"; exec sleep 600"#, "sh", markers],
                    timeout: timeout
                )
            )
        }
        guard let result else { return }

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
    func timeoutClassification() async throws {
        let result = try await timedOutRunPastMarkers(["printed"]) { timeout, markers in
            await ProcessBinaryRunner().run(
                path: "/bin/sh",
                args: ["-c", #"printf out; printf err >&2; : > "$1/printed"; exec sleep 600"#, "sh", markers],
                timeout: timeout,
                environment: nil
            )
        }
        guard let result else { return }

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

    @Test(
        "A timed-out result keeps the child's last words without waiting on its orphans",
        arguments: [false, true]
    )
    func timedOutResultKeepsLastWordsWithoutWaitingOnOrphans(terminateProcessGroup: Bool) async throws {
        // The child answers SIGTERM by printing and exiting 0, so it writes
        // `late` only after the deadline. A result snapshotted at the timeout
        // instant cannot contain it, and a status read off the reap would call
        // the run a success. In process-group mode it also needs a child that
        // can receive SIGTERM at all. That used to fail: the child inherited
        // the spawning GCD thread's mask with SIGTERM blocked.
        //
        // Its background loop inherits stdout and stderr and keeps them open
        // for as long as `hold` exists. The loop ignores SIGTERM, which
        // `Process.terminate()` sends to the child's whole process group.
        // Outside process-group mode the runner's SIGKILL reaches the child
        // alone, so the loop lasts until the test removes `hold`. A runner that
        // drained the pipes to EOF would never return, and the watchdog is what
        // ends that hang. The `holding` marker proves the loop survived SIGTERM.
        let directory = try makeTemporaryDirectory("astra-timeout-orphans")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("hold")
        try Data().write(to: hold)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(hangBreakerTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? FileManager.default.removeItem(at: hold)
        }
        defer { watchdog.cancel() }
        let script = """
        trap 'printf late; : > "$1/late"; exit 0' TERM
        (trap '' TERM; : > "$1/holding"; while [ -e "$2" ]; do sleep 0.05; done) &
        printf early
        : > "$1/early"
        wait
        """

        let result = try await timedOutRunPastMarkers(["early", "late", "holding"]) { timeout, markers in
            await ProcessBinaryRunner().run(
                path: "/bin/sh",
                args: ["-c", script, "sh", markers, hold.path],
                timeout: timeout,
                environment: nil,
                currentDirectory: nil,
                terminateProcessGroup: terminateProcessGroup
            )
        }
        let returnedWhileOrphanHeldPipes = FileManager.default.fileExists(atPath: hold.path)
        guard let result else { return }

        #expect(result.exitCode == nil)
        #expect(result.stdout == "earlylate")
        #expect(returnedWhileOrphanHeldPipes, "The runner waited for an orphan to close the child's pipes")
    }

    @Test(
        "A child reaped just past its deadline is a timeout that does not wait on its orphans",
        arguments: [false, true]
    )
    func childReapedJustPastDeadlineDoesNotWaitOnOrphans(terminateProcessGroup: Bool) async throws {
        // The child exits on its own just after its 0.1 s deadline, so its reap
        // races the timeout task. If the reap lands first, the run is still a
        // timeout, and it must not wait on the orphan holding the pipes. That
        // orphan ignores SIGTERM, and outside process-group mode nothing kills
        // it, so it lasts until its `hold` file goes. Neither ordering is
        // guaranteed in one run, so the test repeats it. Load can only change
        // which side wins, and every iteration passes either way unless the
        // runner is wrong.
        //
        // In process-group mode the timed-out group is torn down whichever side
        // decided the timeout, so there the orphan has to die while `hold` still
        // exists.
        let directory = try makeTemporaryDirectory("astra-timeout-reap-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
        (trap '' TERM; while [ -e "$1" ]; do sleep 0.05; done) &
        printf '%s' "$!" > "$2"
        sleep 0.1
        """#

        for iteration in 0..<20 {
            let hold = directory.appendingPathComponent("hold-\(iteration)")
            let orphanPIDFile = directory.appendingPathComponent("orphan-\(iteration).pid")
            try Data().write(to: hold)
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(hangBreakerTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                try? FileManager.default.removeItem(at: hold)
            }
            defer {
                watchdog.cancel()
                try? FileManager.default.removeItem(at: hold)
            }
            let result = await ProcessBinaryRunner().run(
                path: "/bin/sh",
                args: ["-c", script, "sh", hold.path, orphanPIDFile.path],
                timeout: 0.1,
                environment: nil,
                currentDirectory: nil,
                terminateProcessGroup: terminateProcessGroup
            )
            let returnedWhileOrphanHeldPipes = FileManager.default.fileExists(atPath: hold.path)

            #expect(result.outcome == .timedOut, "iteration \(iteration): \(result.outcome)")
            guard returnedWhileOrphanHeldPipes else {
                Issue.record("iteration \(iteration): the runner waited for an orphan to close the child's pipes")
                return
            }
            if terminateProcessGroup, let orphan = readPID(from: orphanPIDFile) {
                guard await waitUntil({ !processIsRunning(orphan) }) else {
                    kill(orphan, SIGKILL)
                    Issue.record("iteration \(iteration): the timed-out group left orphan \(orphan) alive")
                    return
                }
            }
        }
    }

    @Test("Process group timeout still tears the group down after its leader exits")
    func processGroupTimeoutOutlivesItsLeader() async throws {
        // The leader exits at once, leaving a descendant that ignores SIGTERM
        // and holds the leader's pipes for as long as `hold` exists. The reap's
        // drain then waits on that descendant, so the deadline still has to
        // tear the group down to end the wait, and the run is a timeout. If
        // load keeps the leader alive until the deadline instead, the run ends
        // the same way, so either ordering passes.
        let directory = try makeTemporaryDirectory("astra-group-leader-exits")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("hold")
        try Data().write(to: hold)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(hangBreakerTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? FileManager.default.removeItem(at: hold)
        }
        defer { watchdog.cancel() }

        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", #"(trap '' TERM; while [ -e "$1" ]; do sleep 0.05; done) & exit 0"#, "sh", hold.path],
            timeout: 0.3,
            environment: nil,
            currentDirectory: nil,
            terminateProcessGroup: true
        )
        let returnedWhileHoldExisted = FileManager.default.fileExists(atPath: hold.path)

        #expect(result.outcome == .timedOut)
        #expect(returnedWhileHoldExisted, "Nothing stopped the group's descendant, so the runner waited on it")
    }

    @Test("Process group timeout returns even when the leader's leftovers escape the group")
    func processGroupTimeoutBackstopsAnEscapedDescendant() async throws {
        // The leader exits at once. `set -m` first puts its background loop in
        // a process group of its own, so tearing down the leader's group never
        // reaches it. The loop ignores SIGTERM and holds the leader's pipes for
        // as long as `hold` exists, so only the deadline's backstop can end the
        // run, one grace period after SIGKILL. A runner that waited for EOF
        // would hold out until the watchdog removes `hold`. If load keeps the
        // leader alive until the deadline instead, its own timeout path ends
        // the run, so either ordering passes.
        let directory = try makeTemporaryDirectory("astra-group-escaped-descendant")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("hold")
        try Data().write(to: hold)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(hangBreakerTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? FileManager.default.removeItem(at: hold)
        }
        defer { watchdog.cancel() }

        let result = await ProcessBinaryRunner().run(
            path: "/bin/sh",
            args: ["-c", #"set -m; (trap '' TERM; while [ -e "$1" ]; do sleep 0.05; done) & exit 0"#, "sh", hold.path],
            timeout: 1,
            environment: nil,
            currentDirectory: nil,
            terminateProcessGroup: true
        )
        let returnedWhileHoldExisted = FileManager.default.fileExists(atPath: hold.path)

        #expect(result.outcome == .timedOut)
        #expect(returnedWhileHoldExisted, "The runner waited on a descendant outside the group it tore down")
    }

    @Test("Process group timeout terminates descendant processes")
    func processGroupTimeoutTerminatesDescendants() async throws {
        // The leader marks `forked` once the descendant's PID is on disk, and
        // the descendant marks `ignoring` once SIGTERM can no longer stop it.
        // Those markers need the escalating budgets for the same reason output
        // does. The leader now dies on SIGTERM at the deadline, so a 0.1 s
        // budget can end it before it forks. That used to be hidden: the child
        // inherited a blocked SIGTERM, which gave the leader until the SIGKILL.
        let script = """
        (trap '' TERM; : > "$1/ignoring"; while true; do sleep 1; done) &
        printf "%s" "$!" > "$1/pid"
        : > "$1/forked"
        wait
        """
        var childPID: Int32?
        let result = try await timedOutRunPastMarkers(["forked", "ignoring"]) { timeout, markers in
            let result = await ProcessBinaryRunner().run(
                path: "/bin/sh",
                args: ["-c", script, "sh", markers],
                timeout: timeout,
                environment: nil,
                currentDirectory: nil,
                terminateProcessGroup: true
            )
            childPID = readPID(from: URL(fileURLWithPath: markers).appendingPathComponent("pid"))
            return result
        }
        guard result != nil else { return }
        guard let childPID else {
            Issue.record("The leader marked the descendant's PID as written, but it is unreadable")
            return
        }

        // `run` returns once the group leader is reaped, and SIGTERM alone does
        // that. The descendant ignores SIGTERM and lives until the SIGKILL the
        // runner sends the group 500 ms later. Waiting that out with one fixed sleep
        // measured how busy the machine was, so poll for the descendant to go
        // away instead — same reasoning as `hangBreakerTimeout` above, and the
        // poll floor in `waitUntil` covers a starved cooperative pool that has
        // not yet run the runner's own kill task.
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

    // MARK: - Timed-out output

    /// Runs `attempt` under each of `outputTimeouts` until its child provably
    /// got far enough to print what the test asserts, and returns that run.
    ///
    /// The child's script creates each of `markers` in the directory it is
    /// handed, right after the output that marker vouches for. The runner
    /// returns a timed-out result only once the child can no longer write, so
    /// a marker that exists afterwards was created before then, and so was the
    /// output ahead of it. A missing marker shows only that the child was
    /// killed first. That attempt is inconclusive, and the next budget is longer.
    private func timedOutRunPastMarkers(
        _ markers: [String],
        _ attempt: (_ timeout: TimeInterval, _ markerDirectory: String) async -> RunResult
    ) async throws -> RunResult? {
        let root = try makeTemporaryDirectory("astra-timeout-output")
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, timeout) in outputTimeouts.enumerated() {
            let directory = root.appendingPathComponent("attempt-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = await attempt(timeout, directory.path)
            // Every child here outlives every budget, so each attempt is a
            // timeout, however far the child got.
            #expect(result.outcome == .timedOut, "\(timeout) s attempt: \(result.outcome)")
            let reachedMarkers = markers.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            if reachedMarkers { return result }
        }
        // Several causes look the same from here: a machine too wedged to run
        // a shell in 25.6 s, a runner that returned while its child could still
        // write (its markers then appear after the fact), or a child that never
        // received the SIGTERM a marker waits for.
        Issue.record("""
            No attempt saw the child reach \(markers) before the runner returned \
            (last budget \(outputTimeouts.last ?? 0) s): the machine is wedged, the runner \
            returned while its child could still write, or the child never got SIGTERM
            """)
        return nil
    }

    private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    /// `waitUntil` for a value that may not exist yet.
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
