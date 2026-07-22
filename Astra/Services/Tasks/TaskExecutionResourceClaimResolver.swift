import Foundation
import ASTRAModels
import ASTRAPersistence

/// Resolves the immutable resources an execution request needs before it is
/// persisted. Admission and runtime enforcement must consume this same
/// snapshot so a request can never be scheduled as a reader and launched as a
/// writer.
enum TaskExecutionResourceClaimResolver {
    static func claims(for task: AgentTask) -> [TaskExecutionResourceClaim] {
        guard let key = workspaceKey(for: task) else { return [] }
        return [TaskExecutionResourceClaim(
            kind: .workspace,
            key: key,
            access: workspaceAccess(for: task)
        )]
    }

    static func workspaceClaim(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> TaskExecutionResourceClaim? {
        if let persisted = request?.resourceClaims.first(where: { $0.kind == .workspace }) {
            return persisted
        }
        // V15 rows and partially-created legacy fixtures have no V16 claim.
        // Fail closed to the existing exclusive behavior rather than deriving
        // a new, potentially weaker policy after submission.
        guard let key = workspaceKey(for: task) else { return nil }
        return TaskExecutionResourceClaim(kind: .workspace, key: key, access: .exclusive)
    }

    /// Returns the immutable admission set. Empty, malformed, and legacy
    /// snapshots fail closed to one exclusive workspace claim; a broken JSON
    /// envelope must never make a request appear resource-free.
    static func admissionClaims(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        if let request, !request.resourceClaims.isEmpty {
            let persisted = request.resourceClaims
            if persisted.contains(where: { $0.kind == .workspace }) {
                return persisted
            }
            // Every runtime still receives a workspace root. Additional
            // account/browser/Git claims may narrow global admission but must
            // never replace the workspace safety boundary.
            if let fallback = workspaceClaim(for: nil, task: task) {
                return persisted + [fallback]
            }
            return persisted
        }
        guard let fallback = workspaceClaim(for: nil, task: task) else { return [] }
        return [fallback]
    }

    static func workspaceAccess(for request: TaskTurnRequest?) -> TaskExecutionResourceAccess {
        request?.resourceClaims.first(where: { $0.kind == .workspace })?.access ?? .exclusive
    }

    static func hasWorkspacePathDrift(request: TaskTurnRequest?, task: AgentTask) -> Bool {
        guard let request,
              let persisted = request.resourceClaims.first(where: { $0.kind == .workspace }),
              let liveKey = workspaceKey(for: task) else {
            return false
        }
        return persisted.key != liveKey
    }

    static func workspaceAccess(for task: AgentTask) -> TaskExecutionResourceAccess {
        let declarations = (task.constraints + task.inputs).map(normalizedDeclaration)
        if declarations.contains(where: { containsAccessMarker($0, access: "write") }) {
            return .exclusive
        }
        if declarations.contains(where: { containsAccessMarker($0, access: "read_only") }) {
            return .shared
        }

        // Isolation preparation itself mutates or copies repository state.
        // Keep it exclusive unless the task is pinned to a distinct execution
        // root, in which case workspaceKey(for:) already separates the claim.
        if task.isolationStrategy != .sameDirectory {
            return .exclusive
        }
        if task.validationStrategy == .runTests
            || !task.testCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .exclusive
        }
        if TaskDeliverableExpectation.requiresDeliverableArtifact(task) {
            return .exclusive
        }
        if hasWorkspaceMutationIntent(task) {
            return .exclusive
        }
        return hasInformationalIntent(task) ? .shared : .exclusive
    }

    private static func workspaceKey(for task: AgentTask) -> String? {
        let access = TaskWorkspaceAccess(task: task)
        let rawPath = access.codeWorkingDirectory.isEmpty
            ? access.effectiveWorkspacePath
            : access.codeWorkingDirectory
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func hasWorkspaceMutationIntent(_ task: AgentTask) -> Bool {
        let text = intentText(for: task)
        let mutationWords: Set<String> = [
            "add", "apply", "build", "change", "commit", "configure", "create",
            "delete", "edit", "fix", "generate", "implement", "install", "make",
            "merge", "modify", "move", "patch", "publish", "refactor", "remove",
            "rename", "replace", "revert", "save", "scaffold", "set", "upgrade",
            "update", "write"
        ]
        if TaskIntentLanguagePolicy.containsAffirmativeAction(in: text, words: mutationWords) { return true }
        return [
            "run tests", "run the tests", "execute tests", "git checkout",
            "git rebase", "open a pull request", "create a pull request"
        ].contains { text.contains($0) }
    }

    private static func hasInformationalIntent(_ task: AgentTask) -> Bool {
        let tokens = Set(intentText(for: task)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init))
        let informationalWords: Set<String> = [
            "analyze", "audit", "check", "compare", "describe", "diagnose",
            "explain", "find", "inspect", "investigate", "list", "monitor",
            "read", "research", "review", "summarize", "verify", "watch"
        ]
        return !tokens.isDisjoint(with: informationalWords)
    }

    private static func intentText(for task: AgentTask) -> String {
        [task.title, task.goal, task.acceptanceCriteria.joined(separator: " ")]
            .joined(separator: " ")
            .lowercased()
    }

    private static func normalizedDeclaration(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func containsAccessMarker(_ declaration: String, access: String) -> Bool {
        [
            "astra_resource_access=\(access)",
            "astra_resource_access:\(access)",
            "resource_access=\(access)",
            "resource_access:\(access)"
        ].contains { declaration.contains($0) }
    }
}
