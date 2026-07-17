import Darwin
import Foundation
import Testing

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

        #expect(waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: ready.path)
        })
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

        #expect(waitUntil(timeout: 3) {
            Darwin.kill(supervisedPID, 0) == -1 && errno == ESRCH
        })
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

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}
