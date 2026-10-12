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
        #expect(HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation get-comments --issue-key ASTRA-1 --start-at 20"
        ))
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation get-comments --issue-key ASTRA-1 --start-at -1"
        ))
    }

    @Test("Relay carries proposals only as a named arguments file")
    func relayCarriesProposalsOnlyThroughAnArgumentsFile() {
        // A ticket body or comment is prose the user reviews, and squeezing it
        // through shell quoting either mangles it or is rejected outright. So the
        // fields travel in a JSON file and the command carries only its name.
        for operation in ["propose-issue", "propose-comment", "propose-update", "propose-transition"] {
            #expect(
                HostControlCLIRelayPolicy.allows(
                    "astra-host-control jira --operation \(operation) --alias jira_new --arguments-file jira_proposal.json"
                ),
                "Relay rejects \(operation) with an arguments file"
            )
            #expect(
                !HostControlCLIRelayPolicy.allows("astra-host-control jira --operation \(operation) --alias jira_new"),
                "\(operation) without a file has nothing to stage"
            )
        }
        // Content is never accepted next to the file, or as options on its own.
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose-comment --issue-key ASTRA-1 --arguments-file c.json"
        ))
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose-issue --project-key STAR"
        ))
        // A name, never a path.
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose-comment --arguments-file ../c.json"
        ))
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation propose-comment --arguments-file /tmp/c.json"
        ))
        // Reads take no file, and get-transitions is a read.
        #expect(!HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation get-issue --issue-key ASTRA-1 --arguments-file c.json"
        ))
        #expect(HostControlCLIRelayPolicy.allows(
            "astra-host-control jira --operation get-transitions --issue-key ASTRA-1"
        ))
    }

    /// The relay spelling of the request to post a review file: one bare review
    /// file name, nothing beside it, and the gh route unchanged.
    @Test("Relay allows a post-review request naming exactly one review file")
    func relayAllowsPostReviewRequest() {
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control github --post-review pr12_review.json"))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control github --post-review pr12_review_2.json"))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control github -- pr view 12"))
        for refused in [
            "astra-host-control github --post-review",
            "astra-host-control github --post-review notes.json",
            "astra-host-control github --post-review ../pr12_review.json",
            "astra-host-control github --post-review /tmp/pr12_review.json",
            "astra-host-control github --post-review pr12_review.json --timeout-seconds 5",
            "astra-host-control github --post-review pr12_review.json pr13_review.json",
            "astra-host-control github --post-review pr12_review.json && env"
        ] {
            #expect(!HostControlCLIRelayPolicy.allows(refused), "\(refused)")
        }
    }
}
