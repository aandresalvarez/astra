import Foundation
import ASTRAModels

/// Narrow provider support for ASTRA's typed Ask-mode pull request workflow.
/// Local Git inspection stays read-only; GitHub publication remains an ASTRA
/// operation that is bound to an exact proposal and explicit user approval.
enum AskGitPullRequestWorkflowPolicy {
    static let allowedLocalInspectionShellPatterns = [
        "git status *",
        "git rev-parse *",
        "git remote -v",
        "git remote get-url *"
    ]

    static func isActive(
        task: AgentTask,
        permissionPolicy: PermissionPolicy,
        contextText: String
    ) -> Bool {
        permissionPolicy != .autonomous
            && GitOperationIntentDetector.detectsPullRequestPublicationIntent(
                prompt: contextText,
                task: task,
                contextText: contextText
            )
    }

    static func appendingProviderGuidance(
        to prompt: String,
        task: AgentTask,
        permissionPolicy: PermissionPolicy,
        contextText: String
    ) -> String {
        guard isActive(
            task: task,
            permissionPolicy: permissionPolicy,
            contextText: contextText
        ) else {
            return prompt
        }
        return prompt + """


        ASTRA Ask-mode pull request workflow:
        - ASTRA owns GitHub publication and will require review of an exact typed proposal before it changes Git or GitHub state.
        - You may inspect local repository identity only with `git status`, `git rev-parse`, `git remote -v`, or `git remote get-url`.
        - Do not run `git push`, `git fetch`, `git pull`, `gh pr create`, `gh pr view`, or any other network Git/GitHub command.
        - When local work is ready, report local completion normally. ASTRA will deterministically construct the exact draft pull request proposal and open its typed review workflow.
        """
    }
}
