import Testing
import ASTRACore
@testable import ASTRA

@Suite("Host-control CLI Relay Policy")
struct HostControlCLIRelayPolicyTests {
    @Test("Typed relay bypasses generic Bash denial without allowing shell composition")
    func typedRelayIsTheOnlyBashPolicyException() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read"],
            askFirstTools: ["Bash"],
            deniedTools: ["Bash"],
            allowedShellPatterns: [HostControlCLIRelayPolicy.manifestMarker],
            deniedShellPatterns: ["*"],
            providerID: .cursorCLI
        )
        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest)

        #expect(guardUnderTest.disposition(
            toolName: "Bash",
            command: #"astra-host-control jira --operation search-jql --alias "team" --jql "project = ASTRA" --max-results 1"#
        ) == .allowed)
        #expect(guardUnderTest.disposition(
            toolName: "Bash",
            command: "astra-host-control jira --operation delete"
        ) == .denied)
        #expect(guardUnderTest.disposition(
            toolName: "Bash",
            command: "cd /tmp && astra-host-control jira --operation status"
        ) == .denied)
        #expect(guardUnderTest.disposition(
            toolName: "Bash",
            command: "astra-host-control github -- pr list | cat"
        ) == .denied)
        #expect(guardUnderTest.disposition(
            toolName: "Bash",
            command: "env"
        ) == .denied)
    }

    @Test("Relay allows every typed read-only Jira operation")
    func relayAllowsEveryTypedReadOnlyJiraOperation() {
        // A read operation the bridge supports but the relay rejects is
        // invisible: the agent is told the route exists, then denied at the
        // shell, and reports it has no access.
        for operation in ["status", "get-issue", "search-jql", "get-comments"] {
            #expect(
                HostControlCLIRelayPolicy.allows(
                    "astra-host-control jira --operation \(operation) --issue-key ASTRA-1"
                ),
                "Relay rejects operation \(operation)"
            )
        }
        #expect(!HostControlCLIRelayPolicy.allows("astra-host-control jira --operation add-comment --issue-key ASTRA-1"))
    }

    @Test("Relay does not carry issue proposals")
    func relayDoesNotCarryIssueProposals() {
        // The broker supports propose_issue; this route deliberately does not.
        // A ticket body is content the user reviews, and squeezing it through
        // shell quoting either mangles it or is rejected outright. The MCP tool
        // takes it as structured arguments.
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose-issue --project-key STAR"
        ))
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose_issue --summary Broken"
        ))
    }
}
