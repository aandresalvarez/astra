import Darwin
import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("AgentExecutionScopedProcess")
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

    @Test("dedicated event file descriptor is isolated from stdout diagnostics")
    func dedicatedEventFileDescriptorIsIsolatedFromStdoutDiagnostics() async throws {
        let directory = temporaryDirectory()
        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'stdout-log\\n'; printf 'event-line\\n' >&3; printf 'stderr-log\\n' >&2"],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"],
            dedicatedEventFileDescriptor: 3
        )

        let exitCode = await runAndWait(process)
        let eventOutput = String(data: process.eventFileHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stdoutOutput = String(data: process.stdoutFileHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrOutput = String(data: process.stderrFileHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(exitCode == 0)
        #expect(process.usesDedicatedEventStream)
        #expect(eventOutput == "event-line\n")
        #expect(stdoutOutput == "stdout-log\n")
        #expect(stderrOutput == "stderr-log\n")
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

    @Test("request cancellation writes structured control message")
    func requestCancellationWritesStructuredControlMessage() async throws {
        let directory = temporaryDirectory()
        let readyFile = directory.appendingPathComponent("ready")
        let controlFile = directory.appendingPathComponent("control.json")
        let script = directory.appendingPathComponent("control.sh")
        try """
        #!/bin/sh
        echo ready > "\(readyFile.path)"
        IFS= read -r message <&4
        printf '%s\\n' "$message" > "\(controlFile.path)"
        printf 'cancelled-event\\n' >&3
        exit 130
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: [script.path],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"],
            dedicatedEventFileDescriptor: 3,
            dedicatedControlFileDescriptor: 4
        )

        let completion = Task { await runAndWait(process) }
        let isReady = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: readyFile.path)
        }
        #expect(isReady)

        process.requestCancellation(reason: "cancelled_by_user")
        let exitCode = await completion.value
        let eventOutput = String(data: process.eventFileHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let controlData = try Data(contentsOf: controlFile)
        let control = try JSONDecoder().decode(LocalModelControlMessage.self, from: controlData)

        #expect(exitCode == 130)
        #expect(process.usesDedicatedControlStream)
        #expect(eventOutput == "cancelled-event\n")
        #expect(control == .cancel(reason: "cancelled_by_user"))
    }

    @Test("request cancellation falls back when control pipe is closed")
    func requestCancellationFallsBackWhenControlPipeIsClosed() async throws {
        let directory = temporaryDirectory()
        let readyFile = directory.appendingPathComponent("ready")
        let script = directory.appendingPathComponent("closed-control.sh")
        try """
        #!/bin/sh
        exec 4<&-
        echo ready > "\(readyFile.path)"
        /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: [script.path],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"],
            dedicatedControlFileDescriptor: 4
        )

        let completion = Task { await runAndWait(process) }
        let isReady = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: readyFile.path)
        }
        #expect(isReady)

        process.requestCancellation(reason: "cancelled_by_user")
        let exitCode = await completion.value

        #expect(exitCode == 143 || exitCode == 137)
        #expect(!process.isRunning)
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

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func canonicalPath(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private\(path)" : path
    }
}
