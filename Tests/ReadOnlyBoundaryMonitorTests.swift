import Foundation
import Testing
import ASTRACore
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
        // A genuinely denied write surfaces as a FAILED tool result (isError).
        let resultShouldKill = monitor.processEvent(
            .toolResult(
                toolId: "t1",
                content: "/bin/rm: \(protectedPath): Read-only file system",
                isError: true
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

    @Test("Reading a protected input whose content mentions the denial marker does not kill the run")
    func readingDenialMarkerContentIsNotTerminal() throws {
        // Regression: a read-only INPUT (e.g. an attached build log) can legally
        // contain the literal "Read-only file system" text next to a protected
        // path. A successful read of that content (isError == false) must never
        // be mistaken for an actual denied write.
        let protectedPath = "/mnt/astra/input-1/build.log"
        let boundary = ReadOnlyInputEnforcementBoundary(
            paths: [protectedPath],
            executionEnvironment: WorkspaceExecutionEnvironment(
                id: "image:test",
                kind: .dockerImage,
                displayName: "Test",
                image: "astra/test:latest",
                providerPlacement: .container
            )
        )
        let receipt = try #require(boundary.receipt(appliedSurfaces: [.providerContainer]))
        let process = ReadOnlyBoundaryMockProcess()
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            readOnlyBoundaryReceipt: receipt
        )

        _ = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "cat '\(protectedPath)'"]),
            process: process
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "t1",
                content: "build step failed earlier: /bin/rm: \(protectedPath): Read-only file system",
                isError: false
            ),
            process: process
        )

        #expect(shouldKill == false)
        #expect(process.didTerminate == false)
        #expect(monitor.runtimeStopReason == nil)
        #expect(monitor.policyApprovalRequired == false)
    }

    @Test("Receipt-only monitoring ignores unrelated and ambiguous OS denials")
    func receiptOnlyMonitoringIsLimitedToProtectedWrites() throws {
        let protectedPath = "/workspace/attached.pdf"
        let boundary = ReadOnlyInputEnforcementBoundary(
            paths: [protectedPath],
            executionEnvironment: WorkspaceExecutionEnvironment(
                id: "image:test",
                kind: .dockerImage,
                displayName: "Test",
                image: "astra/test:latest",
                providerPlacement: .container
            )
        )
        let receipt = try #require(boundary.receipt(appliedSurfaces: [.providerContainer]))

        for (path, output) in [
            ("/workspace/unrelated", "/bin/sh: /workspace/unrelated: Operation not permitted"),
            (protectedPath, "/bin/sh: \(protectedPath): Operation not permitted")
        ] {
            let process = ReadOnlyBoundaryMockProcess()
            let monitor = AgentRuntimeWorker.ProcessMonitor(
                tokenBudget: Int.max,
                readOnlyBoundaryReceipt: receipt
            )
            _ = monitor.processEvent(
                .toolUse(name: "Bash", id: path, input: ["command": "inspect '\(path)'"]),
                process: process
            )
            let shouldKill = monitor.processEvent(
                .toolResult(toolId: path, content: output),
                process: process
            )

            #expect(shouldKill == false)
            #expect(process.didTerminate == false)
            #expect(monitor.runtimeStopReason == nil)
            #expect(monitor.policyApprovalRequired == false)
        }
    }
}
