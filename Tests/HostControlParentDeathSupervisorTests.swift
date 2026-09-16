import Darwin
import Foundation
import Testing

/// Budget for the two waits below. Both are waiting on a *separate process* to
/// reach a milestone — the supervised child signalling ready, and the watchdog
/// reaping it once the harness is SIGKILLed — and neither is asserting how fast
/// that happens. They exist to stop a broken supervisor from hanging the suite,
/// so the budget has to sit far above anything the machine can plausibly cost
/// us.
///
/// At 3 seconds it did not: in the full `swift test` run on 2026-09-05 the ready
/// wait expired before the harness had started its child, and the PID read below
/// then failed with ENOENT as a second, misleading issue. The same test finishes
/// in 0.8 s standalone and took 8.2 s under load. See the matching constant in
/// `Tests/BinaryRunnerTests.swift` for the full reasoning — spawning a process in
/// this binary has been measured at ~5 s under that contention, so any budget in
/// the same order as normal execution is measuring how busy the machine was.
private let hangBreakerTimeout: TimeInterval = 120

@Suite("Host Control Parent-Death Supervisor", .serialized)
struct HostControlParentDeathSupervisorTests {
    @Test("Supervisor kills descendants when its parent is killed")
    func killsDescendantsWhenParentIsKilled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-host-parent-death-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let ready = root.appendingPathComponent("ready", isDirectory: false)
        let pidFile = root.appendingPathComponent("pid", isDirectory: false)
        let executable = try customExecutable(named: "ignores-term", root: root, body: """
        trap '' TERM HUP INT
        printf '%s' "$$" > "\(pidFile.path)"
        : > "\(ready.path)"
        while :; do /bin/sleep 1; done
        """)
        let harness = try TestRepositoryRoot.resolve()
            .appendingPathComponent(".build/debug/astra-host-control-crash-harness", isDirectory: false)
        #expect(FileManager.default.isExecutableFile(atPath: harness.path))

        let process = Process()
        process.executableURL = harness
        process.arguments = [executable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        var supervisedPID: pid_t = 0
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if supervisedPID > 0, Darwin.kill(supervisedPID, 0) == 0 {
                let group = getpgid(supervisedPID)
                if group > 0, group != getpgrp() {
                    Darwin.kill(-group, SIGKILL)
                }
            }
        }

        // The child writes its PID before it touches the ready file, so the read
        // below cannot race — but only if we actually saw ready appear. Require
        // rather than expect: without it a slow spawn fails twice, once here and
        // once as an ENOENT on a PID file that was never going to exist.
        try #require(
            waitUntil(timeout: hangBreakerTimeout) {
                FileManager.default.fileExists(atPath: ready.path)
            },
            "Supervised child never signalled ready, so nothing below is testing the supervisor."
        )
        supervisedPID = pid_t(try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )))
        #expect(supervisedPID > 0)

        // SIGKILL deliberately bypasses every Swift defer/deinit/termination
        // handler in the harness. Only the kernel lifetime-pipe EOF and the
        // out-of-process watchdog can clean up the supervised process group.
        #expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0)
        process.waitUntilExit()

        let supervisedProcessWasReaped = waitUntil(timeout: hangBreakerTimeout) {
            Darwin.kill(supervisedPID, 0) == -1 && errno == ESRCH
        }
        #expect(
            supervisedProcessWasReaped,
            "Supervised process \(supervisedPID) outlived the harness that was killed above."
        )
    }

    private func customExecutable(named name: String, root: URL, body: String) throws -> URL {
        let executable = root.appendingPathComponent(name, isDirectory: false)
        try """
        #!/bin/sh
        \(body)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// Exhausts a minimum poll count as well as the deadline. Under full-suite
    /// load this thread can be descheduled for most of its own window, and a
    /// wait that got to sample the child only once or twice is not evidence
    /// that the child never got there. A satisfied condition still returns on
    /// the next poll, so the floor costs nothing on the happy path.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        while !condition() {
            guard polls < 40 || Date() < deadline else { return false }
            polls += 1
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}
