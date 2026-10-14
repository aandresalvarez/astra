import Foundation
import ASTRACore

/// An action ASTRA can take outside the machine on the user's behalf.
///
/// The agent's own tools are governed by the provider render
/// (`ProviderPolicyModeResolver`); these are the actions ASTRA performs or
/// owns itself, and each one used to read the policy level its own way —
/// some not at all. See docs/specs/2026-10-07-permission-levels-harmonization.md.
enum ExternalActionKind: String, Codable, CaseIterable, Sendable {
    /// First use of a connector's saved credentials in a task.
    case connectorCredentialUse
    /// A write to a connector, e.g. creating or commenting on a Jira issue.
    case connectorMutation
    /// Pushing a branch and opening a draft pull request.
    case gitPullRequestPublication
    /// Posting a pull-request review composed by the agent.
    case githubReviewPublication
    /// Replying to a pull-request review thread.
    case githubThreadReply
    /// Resolving a pull-request review thread.
    case githubThreadResolution
    /// A command with an external effect the agent ran with its own tools,
    /// such as `git push` or `gh pr create`. In Ask the run guard asks before
    /// it like any other command; in Auto ASTRA only observes and records it.
    case agentCommand
}

/// What ASTRA does about an external action at a given level.
enum ExternalActionDisposition: Equatable, Sendable {
    /// Stage the action and ask: a review sheet or a chat card.
    case askUser
    /// Act without asking and leave a visible record in the chat.
    case performAndRecord
}

/// Who authorized an external action that happened. Stored on receipts so the
/// chat can say whether the user approved it or a level did.
enum ExternalActionAuthorization: String, Codable, Sendable {
    /// The user reviewed this exact action in a sheet or card.
    case userReviewed = "user_reviewed"
    /// The user approved this kind of action for the whole task.
    case userGrantedForTask = "user_granted_for_task"
    /// Auto performed it without asking.
    case autoPolicy = "auto_policy"
    /// The agent did it with its own tools; ASTRA only observed it.
    case agentObserved = "agent_observed"
}

/// The one answer to "does this level ask before acting outside ASTRA?".
///
/// Ask: ASTRA asks before every external action. Auto: ASTRA asks nothing and
/// records what it did. Custom has no per-item knob for external actions, so it
/// follows Ask. Every caller passes the user-facing level of the run that
/// produced the action, so a proposal composed under Ask is still reviewed
/// after the task switches to Auto.
///
/// In Auto a staged connector write and a requested GitHub review are sent
/// when the agent asks, as its own `git push` happens when it runs: the broker
/// asks ASTRA, ASTRA sends through the same checks the review sheet uses, and
/// the receipt is the agent's tool result (`BrokeredExternalActionHandler`,
/// spec decision 15). Nothing waits for the run to end, so no state the run
/// reaches afterwards decides whether to send.
enum ExternalActionPolicy {
    static func disposition(
        for kind: ExternalActionKind,
        level: AgentPolicyLevel
    ) -> ExternalActionDisposition {
        switch kind {
        case .connectorCredentialUse,
             .connectorMutation,
             .gitPullRequestPublication,
             .githubReviewPublication,
             .githubThreadReply,
             .githubThreadResolution,
             .agentCommand:
            return level.userFacingLevel == .autonomous ? .performAndRecord : .askUser
        }
    }

    static func asksUser(for kind: ExternalActionKind, level: AgentPolicyLevel) -> Bool {
        disposition(for: kind, level: level) == .askUser
    }
}
