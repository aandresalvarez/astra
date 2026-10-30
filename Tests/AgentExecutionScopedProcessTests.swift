import Darwin
import Foundation
import os
import Testing
@testable import ASTRA

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

    @Test("Reaping releases a completion callback that captures its process")
    func reapingReleasesCompletionCapture() async {
        let reference = WeakProcessReference()
        await runCapturingCompletion(reference)
        let released = await waitUntil(timeout: 2) { reference.value == nil }
        // Also break the cycle after a failing regression run.
        defer { reference.value?.terminationHandler = nil }
        #expect(released, "Finished worker callbacks must not retain the process and its output buffers")
    }

    private func runCapturingCompletion(_ reference: WeakProcessReference) async {
        let process = AgentExecutionScopedProcess(executablePath: "/usr/bin/true", arguments: [],
                                                   currentDirectory: "/tmp", environment: [:])
        reference.value = process
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The worker's line parser captures process in this same way.
            process.terminationHandler = { _ in
                _ = process.terminationStatus
                continuation.resume()
            }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume() }
        }
    }

    @Test("A failed launch releases callbacks and their captured process")
    func failedLaunchReleasesCaptures() async {
        let reference = WeakProcessReference()
        captureFailedLaunch(reference)
        let released = await waitUntil(timeout: 2) { reference.value == nil }
        defer {
            reference.value?.stdoutFileHandle.readabilityHandler = nil
            reference.value?.terminationHandler = nil
        }
        #expect(released)
    }

    private func captureFailedLaunch(_ reference: WeakProcessReference) {
        let process = AgentExecutionScopedProcess(executablePath: "/astra-missing-provider-\(UUID())", arguments: [],
                                                   currentDirectory: "/tmp", environment: [:])
        reference.value = process
        process.terminationHandler = { _ in _ = process.terminationStatus }
        process.stdoutFileHandle.readabilityHandler = { _ in _ = process.isRunning }
        #expect(throws: (any Error).self) { try process.run() }
    }

    @Test("Final launch validation rejects a child and releases all captured callbacks")
    func rejectedValidationReleasesCaptures() async {
        let reference = WeakProcessReference()
        do {
            let process = AgentExecutionScopedProcess(executablePath: "/usr/bin/true", arguments: [],
                currentDirectory: "/tmp", environment: [:])
            reference.value = process
            process.terminationHandler = { _ in _ = process.terminationStatus }
            process.stdoutFileHandle.readabilityHandler = { _ in _ = process.isRunning }
            process.stderrFileHandle.readabilityHandler = { _ in _ = process.isRunning }
            #expect(throws: ProviderSharedStateIdentity.Failure.self) {
                try process.run { throw ProviderSharedStateIdentity.Failure(detail: "fixture rejected final identity") }
            }
            #expect(process.processIdentifier == 0)
            #expect(process.stdoutFileHandle.readabilityHandler == nil)
            #expect(process.stderrFileHandle.readabilityHandler == nil)
            #expect(process.terminationHandler == nil)
        }
        let released = await waitUntil(timeout: 2) { reference.value == nil }
        defer {
            reference.value?.stdoutFileHandle.readabilityHandler = nil
            reference.value?.stderrFileHandle.readabilityHandler = nil
            reference.value?.terminationHandler = nil
        }
        #expect(released)
    }

    @Test("terminate kills background child process")
    func terminateKillsBackgroundChildProcess() async throws {
        let directory = temporaryDirectory()
        let script = directory.appendingPathComponent("runaway.sh")
        // The child's pid is printed only once the TERM trap is set, so the
        // test waits for the script to get there, not for a deadline. Signalled
        // as a group, the child dies of SIGTERM while the shell's trap is alive
        // to report it; signalled alone, the shell's trap waits on a live child
        // and is killed before it can report anything. run() is called from a
        // worker thread that blocks SIGTERM, so this also pins the spawn's
        // empty signal mask: inherit that block and no SIGTERM lands at all.
        try """
        #!/bin/sh
        /bin/sleep 30 &
        child=$!
        trap 'wait "$child"; echo "child exited $?"; exit 0' TERM
        echo "$child"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = AgentExecutionScopedProcess(
            executablePath: "/bin/sh",
            arguments: [script.path],
            currentDirectory: directory.path,
            environment: ["PATH": "/bin:/usr/bin"]
        )
        var output = stdoutLines(of: process).makeAsyncIterator()

        let completion = Task { await runAndWait(process) }

        let pidLine = await output.next()
        let childPID = try #require(pidLine.flatMap { pid_t($0) }, "script never printed its child's pid")
        #expect(processIsRunning(childPID))

        process.terminate()
        _ = await completion.value

        // 143 is 128 + SIGTERM, delivered before the shell exited: terminate()
        // reached the child itself, not the residual cleanup after the reap.
        let report = await output.next()
        #expect(report == "child exited 143")
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
            !processIsRunning(childPID)
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

    /// The lines `process` writes to stdout, each as soon as the child writes
    /// it. The stream ends at EOF: once every holder of the pipe, background
    /// children included, has exited.
    private func stdoutLines(of process: AgentExecutionScopedProcess) -> AsyncStream<String> {
        AsyncStream { continuation in
            let pending = OSAllocatedUnfairLock(initialState: Data())
            process.stdoutFileHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                let lines = pending.withLock { buffer in
                    buffer.append(chunk)
                    var lines: [String] = []
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
                        buffer.removeSubrange(...newline)
                    }
                    return lines
                }
                lines.forEach { continuation.yield($0) }
            }
        }
    }

    private func canonicalPath(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private\(path)" : path
    }
}

private final class WeakProcessReference: @unchecked Sendable {
    weak var value: AgentExecutionScopedProcess?
}
