import Darwin
import Foundation
import Testing
import ASTRACore

@Suite("Joined preparation process evidence")
struct BinaryProcessGroupCompletionTests {
    @Test("An executable that never spawned has positive no-launch evidence")
    func noLaunch() async {
        let result = await ProcessBinaryRunner().run(path: "/missing/astra-qa-probe", args: [], timeout: 5,
            environment: nil, currentDirectory: nil, terminateProcessGroup: true, verifyProcessGroupStop: true)
        #expect(result.launchError != nil && result.processGroupStopped == true)
    }

    @Test("A reaped leader cannot certify a group with a live child")
    func liveChild() async throws {
        let result = await ProcessBinaryRunner().run(path: "/bin/sh",
            args: ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"], timeout: 5,
            environment: nil, currentDirectory: nil, terminateProcessGroup: true, verifyProcessGroupStop: true)
        let child = try #require(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        #expect(result.exitCode == 0)
        #expect(kill(child, 0) == 0)
        #expect(result.processGroupStopped == false)
    }

    @Test("Cancellation returns joined evidence only after an uncooperative child is reaped")
    func cancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-joined-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pid")
        let execution = Task {
            await ProcessBinaryRunner().run(path: "/bin/sh",
                args: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 30", "probe", marker.path], timeout: 10,
                environment: nil, currentDirectory: nil, terminateProcessGroup: true, verifyProcessGroupStop: true)
        }
        defer { execution.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        execution.cancel()
        let result = await execution.value
        #expect(result.cancelled && result.processGroupStopped == true)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(kill(-pid, 0) == -1 && errno == ESRCH)
    }
}
