import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The runtime guard sits between an MCP runtime and the host-control broker:
/// every tool call the provider reports is checked against the input keys the
/// projection declared for that tool, and a key outside that list kills the run.
///
/// A proposal operation only exists if the guard lets its arguments through. The
/// broker can validate and stage a perfectly good `propose_issue`, and none of it
/// matters if the provider's stream monitor stops the run first.
@Suite("Jira proposal runtime guard")
struct JiraProposalRuntimeGuardTests {
    private static let mcpRuntimes: [AgentRuntimeID] = [.claudeCode, .codexCLI]

    @Test("A propose_issue call carries only keys the guard allows")
    func proposeIssueSurvivesTheGuard() {
        for runtime in Self.mcpRuntimes {
            let monitor = monitor(for: runtime)
            let shouldKill = monitor.processEvent(
                .toolUse(
                    name: HostControlPlaneMCPProjection.providerToolPermission(for: "jira"),
                    id: "jira-propose-issue",
                    input: [
                        "operation": "propose_issue",
                        "project_key": "STAR",
                        "issue_type": "Bug",
                        "summary": "Age filter missing",
                        "description": "dose_era has no age filter.",
                        "priority": "High",
                        "labels": ["deid"],
                        "assignee_account_id": "5dc098e4a693ee0df50f941c",
                        "parent_key": "STAR-1"
                    ]
                ),
                process: nil
            )

            #expect(shouldKill == false, "\(runtime): \(monitor.policyViolationMessage ?? "")")
            #expect(monitor.policyViolation == false)
        }
    }

    @Test("Comment, update and transition proposals carry only keys the guard allows")
    func everyProposalOperationSurvivesTheGuard() {
        let operations: [String: [String: Any]] = [
            "propose_comment": ["issue_key": "SS-617", "comment": "Hi", "visibility": "public"],
            "propose_update": [
                "issue_key": "STAR-7", "summary": "s", "description": "d", "priority": "High",
                "labels": ["deid"], "assignee_account_id": "5dc098e4a693ee0df50f941c"
            ],
            "propose_transition": [
                "issue_key": "SS-617", "transition_id": "21", "transition_name": "Done", "resolution": "Done"
            ],
            "get_transitions": ["issue_key": "SS-617"]
        ]

        for runtime in Self.mcpRuntimes {
            for (operation, fields) in operations {
                let monitor = monitor(for: runtime)
                var input = fields
                input["operation"] = operation
                input["alias"] = "jira"
                let shouldKill = monitor.processEvent(
                    .toolUse(
                        name: HostControlPlaneMCPProjection.providerToolPermission(for: "jira"),
                        id: "jira-\(operation)",
                        input: input
                    ),
                    process: nil
                )

                #expect(shouldKill == false, "\(runtime) \(operation): \(monitor.policyViolationMessage ?? "")")
                #expect(monitor.policyViolation == false)
            }
        }
    }

    /// The vocabulary is `comment`, not `body`, because the guard reads `body` as a
    /// raw request body — the thing this tool's contract says the agent never
    /// supplies. Widening the allowed keys for the proposals must not have widened
    /// that.
    @Test("A raw request body on the Jira tool is still stopped")
    func rawRequestBodyIsStillStopped() {
        for runtime in Self.mcpRuntimes {
            let monitor = monitor(for: runtime)
            let shouldKill = monitor.processEvent(
                .toolUse(
                    name: HostControlPlaneMCPProjection.providerToolPermission(for: "jira"),
                    id: "jira-raw-body",
                    input: [
                        "operation": "propose_comment",
                        "issue_key": "SS-617",
                        "visibility": "public",
                        "body": "text"
                    ]
                ),
                process: nil
            )

            #expect(shouldKill == true, "\(runtime)")
            #expect(monitor.policyViolation == true)
        }
    }

    private func monitor(for runtime: AgentRuntimeID) -> AgentRuntimeWorker.ProcessMonitor {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: runtime,
            runtimeSupportTools: HostControlPlaneMCPProjection.runtimeSupportToolDescriptors(for: runtime)
        )
        return AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )
    }
}
