import Foundation
import Testing
@testable import ASTRA

@Suite("Task failure reason presentation")
struct TaskFailureReasonPresentationTests {
    @Test("Docker missing executable errors are not presented as missing workspaces")
    func dockerMissingExecutableIsNotPresentedAsMissingWorkspace() {
        let payload = """
        Missing provider executable "claude" inside Docker image astra-starr-data-lake:latest. ASTRA started Docker, but Docker could not exec the provider command in the container.
        """

        #expect(TaskFailureReasonPresentation.reason(
            errorPayloads: [payload],
            latestExitCode: 127
        ) == "Docker image is missing the provider CLI.")
    }

    @Test("Workspace not found errors still use workspace copy")
    func workspaceNotFoundStillUsesWorkspaceCopy() {
        #expect(TaskFailureReasonPresentation.reason(
            errorPayloads: ["Workspace directory not found: /missing/workspace"],
            latestExitCode: -1
        ) == "Workspace directory not found.")
    }

    @Test("Managed workspace job heartbeat failures have clear copy")
    func managedWorkspaceJobHeartbeatFailureHasClearCopy() {
        let payload = """
        ASTRA stopped the provider because managed workspace job dbt-build stopped producing a fresh heartbeat for 7200 seconds.
        """

        #expect(TaskFailureReasonPresentation.reason(
            errorPayloads: [payload],
            latestExitCode: 143
        ) == "Workspace job stopped producing heartbeats.")
    }
}
