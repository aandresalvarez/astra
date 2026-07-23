import Foundation
import Testing
import ASTRAModels
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

    @Test("TaskRunLaunchBlockPayload round-trips through JSON and preserves the suggested runtime")
    func launchBlockPayloadRoundTripsThroughJSON() throws {
        let payload = TaskRunLaunchBlockPayload(
            kind: .runtimeIncompatible,
            title: "Selected runtime is incompatible with required ASTRA capabilities",
            message: "Cursor CLI cannot satisfy: host-control MCP server for github.",
            remediation: "Switch to Codex CLI.",
            missingCapabilities: ["host-control MCP server for github"],
            suggestedRuntimeID: "codex_cli"
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try #require(TaskRunLaunchBlockPayload.decode(from: json))
        #expect(decoded == payload)
        #expect(decoded.suggestedRuntimeID == "codex_cli")
    }

    @Test("TaskRunLaunchBlockPayload.decode returns nil for malformed JSON")
    func launchBlockPayloadDecodeReturnsNilForMalformedInput() {
        #expect(TaskRunLaunchBlockPayload.decode(from: "not json") == nil)
    }

    @Test("TaskRunLaunchBlockPayload.decode round-trips a block with no suggested runtime")
    func launchBlockPayloadDecodeHandlesMissingSuggestion() throws {
        let payload = TaskRunLaunchBlockPayload(
            kind: .runtimeIncompatible,
            title: "Selected runtime is incompatible with required ASTRA capabilities",
            message: "Cursor CLI cannot satisfy: host-control MCP server for jira.",
            remediation: "Switch to a compatible runtime such as Codex CLI, Claude Code, or a Copilot CLI build with task-scoped MCP config support.",
            missingCapabilities: ["host-control MCP server for jira"]
        )
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try #require(TaskRunLaunchBlockPayload.decode(from: json))
        #expect(decoded.suggestedRuntimeID == nil)
    }

    @Test("TaskRunLaunchBlockPayload decodes payloads written before Docker recovery fields existed")
    func launchBlockPayloadDecodesLegacyJSON() throws {
        let json = """
        {
          "kind": "runtimeIncompatible",
          "title": "Runtime unavailable",
          "message": "The selected runtime cannot launch this task.",
          "missingCapabilities": []
        }
        """

        let decoded = try #require(TaskRunLaunchBlockPayload.decode(from: json))
        #expect(decoded.dockerImage == nil)
        #expect(decoded.dockerImageID == nil)
        #expect(decoded.dockerReadinessState == nil)
    }
}
