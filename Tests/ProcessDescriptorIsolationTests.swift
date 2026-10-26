import Darwin
import Foundation
import Testing
import ASTRACore
import HostControlToolSupport
@testable import ASTRA

@Suite("Spawned processes isolate unrelated descriptors", .serialized)
struct ProcessDescriptorIsolationTests {
    @Test("Concurrent spawners cannot retain another provider's stdout or stderr", arguments: ["agent", "binary", "host"])
    func unrelatedPipes(spawner: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("descriptor-isolation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        // A owns open pipes before B starts. The handshake makes the leak
        // deterministic, independent of parallel test scheduling or timeouts.
        let first = AgentExecutionScopedProcess(executablePath: "/bin/sh",
            arguments: ["-c", "printf complete; printf warning >&2"], currentDirectory: root.path, environment: [:])
        let other = Task { await runOther(spawner, root: root) }
        defer { try? Data().write(to: release); other.cancel() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        #expect(await run(first) == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path))
        for (handle, expected) in [(first.stdoutFileHandle, "complete"), (first.stderrFileHandle, "warning")] {
            var output = Data()
            let eof = AgentProcessPipeReader(handle).finish { output.append($0) }
            #expect(String(decoding: output, as: UTF8.self) == expected)
            #expect(eof, "\(spawner) retained an unrelated writer and prevented reliable completion proof")
        }
        try Data().write(to: release)
        #expect(await other.value == 0)
    }

    @Test("A provider's explicit stdin pipe still delivers input and EOF")
    func explicitStdin() async {
        let process = AgentExecutionScopedProcess(executablePath: "/bin/cat", arguments: [],
            currentDirectory: NSTemporaryDirectory(), environment: [:], stdinMode: .pipe)
        let code: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                #expect(process.writeStdinLine("scoped input"))
                #expect(process.closeStdinChannel())
            } catch { continuation.resume(returning: -1) }
        }
        #expect(code == 0)
        #expect(String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self) == "scoped input\n")
    }

    @Test("Inherited stdin remains available when the parent has it open")
    func inheritedStdin() async throws {
        var info = stat()
        let isOpen = fstat(STDIN_FILENO, &info) == 0
        let process = AgentExecutionScopedProcess(executablePath: "/usr/bin/stat", arguments: ["-Lf", "%d:%i", "/dev/fd/0"],
            currentDirectory: NSTemporaryDirectory(), environment: [:], stdinMode: .inherited)
        let code = await run(process)
        let output = String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((code == 0) == isOpen)
        if isOpen { #expect(!output.isEmpty) }
    }

    private func runOther(_ spawner: String, root: URL) async -> Int {
        let script = "touch ready; while [ -d \"$PWD\" ] && [ ! -e release ]; do /bin/sleep 0.05; done; touch done"
        switch spawner {
        case "binary":
            let result = await ProcessBinaryRunner().run(path: "/bin/sh", args: ["-c", script], timeout: 60,
                environment: ["PATH": "/bin:/usr/bin"], currentDirectory: root.path, terminateProcessGroup: true)
            return Int(result.exitCode ?? -1)
        case "host":
            return await Task.detached {
                Int(HostControlProcessRunner().run(executablePath: "/bin/sh", arguments: ["-c", script],
                    timeoutSeconds: 60, environment: [:], currentDirectory: root.path).exitCode)
            }.value
        default:
            return Int(await run(AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: ["-c", script],
                currentDirectory: root.path, environment: ["PATH": "/bin:/usr/bin"])))
        }
    }

    private func run(_ process: AgentExecutionScopedProcess) async -> Int32 {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
        } onCancel: { process.terminate() }
    }
}
