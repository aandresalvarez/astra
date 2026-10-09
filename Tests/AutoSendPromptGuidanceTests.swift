import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// What the agent is told a proposal or a review file does has to match what
/// the broker does with it at that level (spec decision 15). The guidance is
/// added only where the contract or the review rule is in the prompt, and only
/// where `ExternalActionPolicy` says the level does not ask.
@Suite("Auto send prompt guidance")
struct AutoSendPromptGuidanceTests {
    private static let contract = HostControlPlanePromptGuidance.mutationUnderReviewContract(usesHostControlCLIRelay: false)
    private static let reviewRule = "ASTRA will show the exact payload and \(HostControlPlanePromptGuidance.reviewPostingMarker)."

    @Test("Auto is told a proposal is sent when made, and how to read each reply")
    func autoConnectorGuidance() {
        let prompt = guided(Self.contract, level: .autonomous)

        #expect(prompt.hasPrefix(Self.contract))
        #expect(prompt.contains("ASTRA Auto mode"))
        #expect(prompt.contains("`sent: true`"))
        #expect(prompt.contains("`parent_key`"))
        #expect(prompt.contains("`sent: unknown`"))
    }

    @Test("Ask, Custom and the legacy presets keep the review contract unchanged")
    func askKeepsTheContract() {
        for level in AgentPolicyLevel.allCases where level != .autonomous {
            #expect(guided(Self.contract + "\n" + Self.reviewRule, level: level, offersGitHub: true)
                == Self.contract + "\n" + Self.reviewRule, "\(level.rawValue)")
        }
    }

    @Test("Nothing is added where neither the contract nor the review rule is in the prompt")
    func nothingWithoutTheContract() {
        #expect(guided("Fix the failing test.", level: .autonomous, offersGitHub: true) == "Fix the failing test.")
    }

    @Test("Auto is told to ask ASTRA to post a review file, over the route the run has")
    func autoReviewGuidanceNamesTheRoute() {
        let mcp = guided(Self.reviewRule, level: .autonomous, offersGitHub: true)
        #expect(mcp.contains(#"{"operation":"post_review","review_file":"pr<NUMBER>_review.json"}"#))
        #expect(!mcp.contains("astra-host-control github --post-review"))

        let relay = guided(Self.reviewRule, level: .autonomous, relay: true, offersGitHub: true)
        #expect(relay.contains("astra-host-control github --post-review pr<NUMBER>_review.json"))
        #expect(!relay.contains("mcp__astra_host__github"))
    }

    /// Naming a request the run cannot make is worse than naming none: the
    /// agent tries it, fails, and reports the review as broken.
    @Test("No review guidance when the run has no GitHub host tool")
    func noReviewGuidanceWithoutTheTool() {
        #expect(guided(Self.reviewRule, level: .autonomous, offersGitHub: false) == Self.reviewRule)
    }

    /// The guidance keys on text the catalog ships, so a reworded rule would
    /// silently stop Auto from being told about the request.
    @Test("The shipped GitHub review rule still carries the marker the guidance keys on")
    func shippedReviewRuleCarriesTheMarker() throws {
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let skill = try #require(package.skills.first)
        #expect(skill.behaviorInstructions.contains(HostControlPlanePromptGuidance.reviewPostingMarker))
        #expect(Self.contract.contains(HostControlPlanePromptGuidance.stagedWritesMarker))
    }

    private func guided(
        _ prompt: String,
        level: AgentPolicyLevel,
        relay: Bool = false,
        offersGitHub: Bool = false
    ) -> String {
        HostControlPlanePromptGuidance.appendingAutoSendGuidance(
            to: prompt,
            policyLevel: level,
            usesHostControlCLIRelay: relay,
            offersGitHubHostTool: offersGitHub
        )
    }
}
