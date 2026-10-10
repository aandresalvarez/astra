import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// The level × external-action contract: Ask asks before acting outside ASTRA,
/// Auto acts and records, Custom follows Ask. `AgentPolicyRuntimeMatrixTests`
/// pins how a level reaches each provider's flags; this pins the actions ASTRA
/// performs or owns itself, so no site can read the level its own way again.
/// See docs/specs/2026-10-07-permission-levels-harmonization.md.
@Suite("Policy level external action matrix")
struct PermissionLevelActionMatrixTests {
    /// Every kind ASTRA knows. A new kind fails the coverage test below until
    /// it is placed here, which is the point: it must not inherit a default.
    private static let declaredKinds: Set<ExternalActionKind> = [
        .connectorCredentialUse,
        .connectorMutation,
        .gitPullRequestPublication,
        .githubReviewPublication,
        .githubThreadReply,
        .githubThreadResolution,
        .agentCommand
    ]

    @Test("The matrix covers every external action kind")
    func matrixCoversEveryKind() {
        #expect(Set(ExternalActionKind.allCases) == Self.declaredKinds)
    }

    /// Reviewed in Auto too until they are sent when the agent asks (spec
    /// decision 15): ASTRA learns of them only after the run.
    private static let reviewedAtEveryLevel: Set<ExternalActionKind> = [.connectorMutation, .githubReviewPublication]

    @Test("Auto performs every other external action without asking and records it")
    func autoPerformsAndRecords() {
        for kind in ExternalActionKind.allCases {
            #expect(
                ExternalActionPolicy.disposition(for: kind, level: .autonomous)
                    == (Self.reviewedAtEveryLevel.contains(kind) ? .askUser : .performAndRecord),
                "Auto \(kind.rawValue)"
            )
        }
    }

    @Test("Ask asks before every external action")
    func askAsksFirst() {
        for kind in ExternalActionKind.allCases {
            #expect(ExternalActionPolicy.disposition(for: kind, level: .review) == .askUser, "Ask \(kind.rawValue)")
        }
    }

    @Test("Custom and the legacy presets follow Ask for external actions")
    func customFollowsAsk() {
        for level in [AgentPolicyLevel.custom, .locked, .build, .network] {
            for kind in ExternalActionKind.allCases {
                #expect(
                    ExternalActionPolicy.disposition(for: kind, level: level) == .askUser,
                    "\(level.rawValue) \(kind.rawValue)"
                )
            }
        }
    }

    @Test("Auto is the only level that acts without asking")
    func autoIsTheOnlyLevelThatActs() {
        for level in AgentPolicyLevel.allCases {
            let acts = ExternalActionKind.allCases.contains {
                ExternalActionPolicy.disposition(for: $0, level: level) == .performAndRecord
            }
            #expect(acts == (level == .autonomous), "\(level.rawValue)")
        }
    }

    @Test("Ask owns pull request publication; Auto leaves it to the agent")
    func gitPublicationFollowsTheLevel() {
        let task = AgentTask(title: "Publish", goal: "Create a pull request for the fix")
        let context = "Create a pull request for the fix"
        #expect(AskGitPullRequestWorkflowPolicy.isActive(task: task, permissionPolicy: .restricted, contextText: context))
        #expect(AskGitPullRequestWorkflowPolicy.isActive(task: task, permissionPolicy: .interactive, contextText: context))
        #expect(!AskGitPullRequestWorkflowPolicy.isActive(task: task, permissionPolicy: .autonomous, contextText: context))
    }
}
