import Foundation
import Testing

@Suite("Isolated permission repair commands")
struct PermissionRepairCommandClientTests {
    @Test("Direct test execution fails explicitly without the harness")
    func missingHarnessFailsClosed() {
        #expect(throws: PermissionRepairCommandClient.Failure.self) {
            try PermissionRepairCommandClient.run("/bin/sh", ["-c", "exit 0"], environment: [:])
        }
    }

    @Test("Real commands execute in the prestarted parent and preserve failure status")
    func commandsRunOutsideTestExecutor() throws {
        let result = try PermissionRepairCommandClient.run("/bin/sh", ["-c", "printf '%s' \"$PPID\"; exit 7"])
        #expect(result.exitCode == 7)
        #expect(result.executorPID != nil)
        #expect(result.executorPID != Int(ProcessInfo.processInfo.processIdentifier))
        #expect(result.stdout == result.executorPID.map(String.init))
    }

    @Test("An invalid endpoint cannot fall back to spawning a process")
    func invalidEndpointFailsClosed() {
        #expect(throws: PermissionRepairCommandClient.Failure.self) {
            try PermissionRepairCommandClient.run("/bin/sh", [], environment: ["ASTRA_PERMISSION_TEST_SOCKET": String(repeating: "x", count: 200)])
        }
    }
}
