import Foundation
import Testing
@testable import ASTRA

let processMonitorAppliedSandboxContext = RuntimeSandboxDiagnosticContext(
    boundaryApplied: true,
    workingDirectory: nil,
    boundaryReceipt: ExecutionSandboxBoundaryReceipt(
        writableRoots: ["/tmp/astra-sandbox-workspace"],
        writeDeniedRoots: [],
        readScope: .enforce,
        readableRoots: ["/tmp/astra-sandbox-workspace"],
        readDeniedRoots: [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures")
                .path
        ]
    )
)

@Suite("Process monitor sandbox attribution")
struct ProcessMonitorSandboxAttributionTests {
    @Test("EPERM inside a sandbox writable root is not attributed to ASTRA")
    func writableRootEPERMIsNotAttributedToSandbox() {
        let workspace = "/tmp/astra-sandbox-workspace"
        let context = RuntimeSandboxDiagnosticContext(
            boundaryApplied: true,
            workingDirectory: workspace,
            boundaryReceipt: processMonitorAppliedSandboxContext.boundaryReceipt
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            sandboxDiagnosticContext: context
        )
        _ = monitor.processEvent(
            .toolUse(
                name: "Bash",
                id: "t1",
                input: ["command": "touch dbt/omop_cdm54/macros/test_write.txt"]
            ),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "t1",
                content: "touch: dbt/omop_cdm54/macros/test_write.txt: Operation not permitted",
                isError: true
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.runtimeStopReason == nil)
        #expect(monitor.policyApprovalRequired == false)
    }

    @Test("Boundary receipts explain only rules that can deny the typed operation")
    func receiptEvidenceIsOperationSpecific() throws {
        let strict = try #require(processMonitorAppliedSandboxContext.boundaryReceipt)
        let outsideRead = RuntimeSandboxFileDenial(
            operation: .read,
            path: "/Users/example/outside.txt",
            detail: ""
        )
        let outsideAccess = RuntimeSandboxFileDenial(
            operation: .access,
            path: "/Users/example/tool",
            detail: ""
        )
        let audit = ExecutionSandboxBoundaryReceipt(
            writableRoots: ["/tmp/astra-sandbox-workspace"],
            writeDeniedRoots: [],
            readScope: .audit,
            readableRoots: ["/tmp/astra-sandbox-workspace"]
        )
        let protectedInput = ExecutionSandboxBoundaryReceipt(
            writableRoots: ["/workspace"],
            writeDeniedRoots: ["/workspace/input"],
            readScope: .open
        )
        let inputWrite = RuntimeSandboxFileDenial(
            operation: .write,
            path: "/workspace/input",
            detail: ""
        )
        let siblingWrite = RuntimeSandboxFileDenial(
            operation: .write,
            path: "/workspace/scratch.txt",
            detail: ""
        )

        #expect(strict.explains(outsideRead))
        #expect(!strict.explains(outsideAccess))
        #expect(!audit.explains(outsideRead))
        #expect(protectedInput.explains(inputWrite))
        #expect(!protectedInput.explains(siblingWrite))
    }
}
