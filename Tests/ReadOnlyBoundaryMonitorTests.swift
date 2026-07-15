import Foundation
import Testing
@testable import ASTRA

private final class ReadOnlyBoundaryMockProcess: AgentRuntimeProcessControl {
    private(set) var didTerminate = false
    var isRunning: Bool { !didTerminate }
    var terminationStatus: Int32 { didTerminate ? 143 : 0 }

    func terminate() {
        didTerminate = true
    }
}

@Suite("Read-only boundary monitor")
struct ReadOnlyBoundaryMonitorTests {
    @Test("Write denial is terminal and never requests approval")
    func writeDenialIsTerminal() throws {
        let protectedPath = "/workspace/attached.pdf"
        let boundary = ReadOnlyInputEnforcementBoundary(
            paths: [protectedPath],
            executionEnvironment: .host
        )
        let receipt = try #require(boundary.receipt(appliedSurfaces: [.hostSeatbelt]))
        let process = ReadOnlyBoundaryMockProcess()
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            readOnlyBoundaryReceipt: receipt
        )

        let toolUseShouldKill = monitor.processEvent(
            .toolUse(
                name: "Bash",
                id: "t1",
                input: ["command": "rm '/workspace/attached.pdf'"]
            ),
            process: process
        )
        let resultShouldKill = monitor.processEvent(
            .toolResult(
                toolId: "t1",
                content: "/bin/rm: \(protectedPath): Read-only file system"
            ),
            process: process
        )

        #expect(toolUseShouldKill == false)
        #expect(resultShouldKill == true)
        #expect(process.didTerminate == true)
        #expect(monitor.runtimeStopReason == "read_only_resource_write_denied")
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }
}
