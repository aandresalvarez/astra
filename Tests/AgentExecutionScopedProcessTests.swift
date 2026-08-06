import Darwin
import Foundation
import Testing
@testable import ASTRA

@Suite("AgentExecutionScopedProcess", .serialized)
struct AgentExecutionScopedProcessTests {
    @Test("runs with scoped cwd and environment")
    func runsWithScopedCWDAndEnvironment() async throws {
        let directory = temporaryDirectory()
        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$PWD\" \"$ASTRA_TEST_VALUE\""],
            currentDirectory: directory.path,
            environment: [
                "ASTRA_TEST_VALUE": "scoped",
                "PATH": "/bin:/usr/bin"
            ]
        )

        let exitCode = await runAndWait(process)
        let output = String(data: process.stdoutFileHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(exitCode == 0)
        #expect(output == "\(canonicalPath(directory.path)):scoped")
    }

    @Test("supervision preserves opaque arguments stdout and exit status")
    func supervisionPreservesProcessSemantics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let argument = "value with spaces; $(not-evaluated)"
        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\"; exit 23", "provider", argument],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        let exitCode = await runAndWait(process)
        let output = String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self)

        #expect(exitCode == 23)
        #expect(output == argument)
        #expect(process.ownerLifetimePipeIsClosedForTesting)
    }

    @Test("supervision preserves the interactive stdin channel")
    func supervisionPreservesInteractiveStdin() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r value; printf '%s' \"$value\""],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"],
            providesStdinChannel: true
        )

        let completion = Task { await runAndWait(process) }
        let launched = await waitUntil(timeout: 2) { process.isRunning }
        #expect(launched)
        process.writeStdinLine("interactive-value")
        let exitCode = await completion.value
        let output = String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self)

        #expect(exitCode == 0)
        #expect(output == "interactive-value")
    }

    @Test("failed launch closes every owner lifetime descriptor")
    func failedLaunchClosesLifetimePipe() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-missing-cwd-\(UUID().uuidString)")
        let process = AgentExecutionScopedProcess(
            executablePath: "/usr/bin/true",
            arguments: [],
            currentDirectory: missingDirectory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        do {
            try process.run()
            Issue.record("Expected launch to fail for a missing working directory")
        } catch {
            #expect(process.ownerLifetimePipeIsClosedForTesting)
        }
    }

    @Test("missing provider preserves launch failure semantics and closes descriptors")
    func missingProviderFailsBeforeSupervision() {
        let process = AgentExecutionScopedProcess(
            executablePath: "/astra/does-not-exist/provider",
            arguments: [],
            currentDirectory: FileManager.default.temporaryDirectory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        do {
            try process.run()
            Issue.record("Expected a missing provider executable to fail before launch")
        } catch {
            #expect(process.ownerLifetimePipeIsClosedForTesting)
            #expect(error.localizedDescription.contains("provider executable preflight"))
        }
    }

    @Test("terminate kills background child process")
    func terminateKillsBackgroundChildProcess() async throws {
        let directory = temporaryDirectory()
        let pidFile = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("runaway.sh")
        try """
        #!/bin/sh
        /bin/sleep 30 &
        echo $! > "\(pidFile.path)"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: [script.path],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        let completion = Task { await runAndWait(process) }

        let wrotePID = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        #expect(wrotePID)

        let childPID = try readPID(from: pidFile)
        #expect(isProcessAlive(childPID))

        process.terminate()
        _ = await completion.value

        let childExited = await waitUntil(timeout: 3) {
            !isProcessAlive(childPID)
        }
        #expect(childExited)
    }

    @Test("provider exit cleans residual background child")
    func providerExitCleansResidualBackgroundChild() async throws {
        let directory = temporaryDirectory()
        let pidFile = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("orphan.sh")
        try """
        #!/bin/sh
        /bin/sleep 30 &
        echo $! > "\(pidFile.path)"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: [script.path],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )

        let exitCode = await runAndWait(process)
        #expect(exitCode == 0)

        let wrotePID = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        #expect(wrotePID)

        let childPID = try readPID(from: pidFile)
        let childExited = await waitUntil(timeout: 2) {
            !isProcessAlive(childPID)
        }
        #expect(childExited)
        #expect(process.ownerLifetimePipeIsClosedForTesting)
    }

    @Test("owner SIGKILL kills TERM-resistant provider and descendant")
    func ownerSIGKILLKillsTermResistantTree() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let providerPIDFile = directory.appendingPathComponent("provider.pid")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let readyFile = directory.appendingPathComponent("ready")
        let script = directory.appendingPathComponent("term-resistant-provider.sh")
        try """
        #!/bin/sh
        trap '' TERM HUP INT
        printf '%s' "$$" > "\(providerPIDFile.path)"
        /bin/sh -c 'trap "" TERM HUP INT; printf "%s" "$$" > "$1"; while :; do /bin/sleep 1; done' astra-child "\(childPIDFile.path)" &
        : > "\(readyFile.path)"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let harness = try TestRepositoryRoot.resolve()
            .appendingPathComponent(".build/debug/astra-agent-process-crash-harness")
        #expect(FileManager.default.isExecutableFile(atPath: harness.path))

        let owner = Process()
        let ownerError = Pipe()
        owner.executableURL = harness
        owner.arguments = [script.path]
        owner.currentDirectoryURL = directory
        owner.standardOutput = FileHandle.nullDevice
        owner.standardError = ownerError
        try owner.run()
        ownerError.fileHandleForWriting.closeFile()

        var providerPID: pid_t = 0
        var childPID: pid_t = 0
        defer {
            if owner.isRunning {
                kill(owner.processIdentifier, SIGKILL)
                reapBounded(owner)
            }
            for pid in [providerPID, childPID] where isProcessAlive(pid) {
                let group = getpgid(pid)
                if group > 0, group != getpgrp() {
                    kill(-group, SIGKILL)
                } else {
                    kill(pid, SIGKILL)
                }
            }
        }

        let becameReady = waitUntilBlocking(timeout: 10) {
            FileManager.default.fileExists(atPath: readyFile.path)
                && FileManager.default.fileExists(atPath: childPIDFile.path)
        }
        if !becameReady {
            if owner.isRunning {
                kill(owner.processIdentifier, SIGKILL)
                reapBounded(owner)
            }
            let diagnostics = String(
                decoding: ownerError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            Issue.record("Crash harness did not become ready: \(diagnostics)")
            return
        }
        providerPID = try readPID(from: providerPIDFile)
        childPID = try readPID(from: childPIDFile)
        #expect(isProcessAlive(providerPID))
        #expect(isProcessAlive(childPID))

        // SIGKILL bypasses every Swift defer, deinit, and termination handler
        // in the owner. Only kernel EOF on the private lifetime pipe can wake
        // the watchdog and clean the process group.
        #expect(kill(owner.processIdentifier, SIGKILL) == 0)
        reapBounded(owner)

        #expect(waitUntilBlocking(timeout: 4) {
            !isProcessAlive(providerPID) && !isProcessAlive(childPID)
        })
    }

    @Test("cancellation escalates against TERM-resistant descendants")
    func cancellationEscalatesAgainstTermResistantDescendants() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("term-resistant-child.sh")
        try """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP INT; printf "%s" "$$" > "$1"; while :; do /bin/sleep 1; done' astra-child "\(childPIDFile.path)" &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: script.path,
            arguments: [],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )
        let completion = Task { await runAndWait(process) }
        #expect(await waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: childPIDFile.path)
        })
        let childPID = try readPID(from: childPIDFile)
        #expect(isProcessAlive(childPID))

        process.terminate()
        _ = await completion.value

        #expect(await waitUntil(timeout: 4) { !isProcessAlive(childPID) })
        #expect(process.ownerLifetimePipeIsClosedForTesting)
    }

    @Test("stale PID metadata is never adopted")
    func stalePIDMetadataIsNeverAdopted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer {
            if unrelated.isRunning {
                unrelated.terminate()
                reapBounded(unrelated)
            }
        }
        try String(unrelated.processIdentifier).write(
            to: directory.appendingPathComponent("provider.pid"),
            atomically: true,
            encoding: .utf8
        )

        let process = AgentExecutionScopedProcess(
            executablePath: "/usr/bin/true",
            arguments: [],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )
        #expect(await runAndWait(process) == 0)
        #expect(unrelated.isRunning)
    }

    private func runAndWait(_ process: AgentExecutionScopedProcess) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-process-scope-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readPID(from file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8)
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func waitUntilBlocking(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// `Process.waitUntilExit` waits on a termination notification that can
    /// be lost, wedging the serial suite until the CI job cap (observed: a
    /// teardown blocked in mach_msg on an already-reaped child). Reap with a
    /// bounded poll instead; a straggler that still reports running after
    /// the bound gets SIGKILL insurance and is abandoned to host orphan
    /// cleanup rather than allowed to hang the run.
    private func reapBounded(_ process: Process, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func canonicalPath(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private\(path)" : path
    }
}
