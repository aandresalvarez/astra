import Foundation
import ASTRACore

enum TextOnlyRuntimeGuard {
    static let stopReason = "text_only_runtime_requires_agent_tools"

    static func blockReason(
        task: AgentTask,
        runtime: AgentRuntimeID,
        contextText: String = ""
    ) -> String? {
        let capabilities = AgentRuntimeAdapterRegistry.executionCapabilities(for: runtime)
        guard !capabilities.canExecuteActions else { return nil }

        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        let text = searchableRequestText(task: task, contextText: contextText)
        guard requestRequiresAction(text, scope: scope) else { return nil }

        return """
        Local Chat can answer from text in the prompt, but it cannot use ASTRA tools, connectors, browser sessions, shell commands, or workspace files yet. Switch this task to Claude Code, GitHub Copilot CLI, Google Antigravity CLI, or a future Local Agent mode for action-based work.
        """
    }

    static func requestRequiresAction(_ text: String, scope: TaskCapabilityPromptScope) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        if mentionsUnavailableConnector(in: normalized, scope: scope) {
            return true
        }
        if mentionsUnavailableTool(in: normalized, scope: scope) {
            return true
        }
        if containsAny(normalized, browserActionTerms) {
            return true
        }
        if containsAny(normalized, taskOutputActionTerms) {
            return true
        }
        if containsAny(normalized, networkActionTerms) {
            return true
        }
        if containsAny(normalized, repositoryActionTerms) {
            return true
        }
        if containsAny(normalized, communicationActionTerms) {
            return true
        }
        if containsAny(normalized, followUpActionTerms) {
            return true
        }
        if containsAny(normalized, externalDataTerms) {
            return true
        }
        if looksLikeWorkspaceFileRequest(normalized) {
            return true
        }
        if containsAny(normalized, shellActionTerms) {
            return true
        }
        if looksLikeFileMutationRequest(normalized) {
            return true
        }
        return false
    }

    private static func looksLikeWorkspaceFileRequest(_ normalized: String) -> Bool {
        guard containsAny(normalized, workspaceFileActionTerms) else {
            return false
        }
        return containsAny(normalized, workspaceFileReferenceTerms)
    }

    private static func looksLikeFileMutationRequest(_ normalized: String) -> Bool {
        if containsAny(normalized, explicitFileMutationTerms) {
            return true
        }
        guard containsAny(normalized, fileMutationActionTerms) else {
            return false
        }
        return containsAny(normalized, workspaceFileReferenceTerms)
    }

    private static func searchableRequestText(task: AgentTask, contextText: String) -> String {
        [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " "),
            contextText
        ].joined(separator: " ")
    }

    private static func mentionsUnavailableConnector(
        in normalized: String,
        scope: TaskCapabilityPromptScope
    ) -> Bool {
        for connector in scope.connectors {
            let terms = [
                connector.name,
                connector.serviceType,
                connector.connectorDescription
            ].map(normalize).filter { !$0.isEmpty }
            if terms.contains(where: { normalized.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func mentionsUnavailableTool(
        in normalized: String,
        scope: TaskCapabilityPromptScope
    ) -> Bool {
        for tool in scope.localTools {
            let terms = [
                tool.name,
                tool.command,
                tool.toolDescription
            ].map(normalize).filter { !$0.isEmpty }
            if terms.contains(where: { normalized.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static let externalDataTerms = [
        "latest ",
        "current ",
        "read my ",
        "show my ",
        "summarize my ",
        "jira",
        "ticket",
        "tickets",
        "story",
        "stories",
        "github",
        "pull request",
        "pr ",
        "issue",
        "issues",
        "google drive",
        "google doc",
        "google docs",
        "gmail",
        "slack",
        "email",
        "mail",
        "redcap",
        "gcloud",
        "bigquery"
    ]

    private static let browserActionTerms = [
        "browser",
        "open ",
        "click",
        "website",
        "web page",
        "read page",
        "read the page",
        "navigate",
        "visit ",
        "screenshot",
        "http://",
        "https://",
        "log in",
        "login"
    ]

    private static let taskOutputActionTerms = [
        "task output",
        "task outputs",
        "output folder",
        "output file",
        "artifact",
        "artifacts",
        ".astra/tasks"
    ]

    private static let networkActionTerms = [
        "call api",
        "call the api",
        "api request",
        "rest api",
        "graphql",
        "webhook",
        "curl ",
        "fetch ",
        "post to ",
        "upload ",
        "download ",
        "send request",
        "make a request"
    ]

    private static let repositoryActionTerms = [
        "create branch",
        "create a branch",
        "new branch",
        "switch branch",
        "checkout branch",
        "open pr",
        "open a pr",
        "create pr",
        "create a pr",
        "open pull request",
        "create pull request",
        "merge pull request",
        "merge pr",
        "git commit",
        "git push",
        "git pull",
        "pull latest",
        "clone repo",
        "clone repository"
    ]

    private static let communicationActionTerms = [
        "send email",
        "send an email",
        "reply to email",
        "send message",
        "send a message",
        "post message",
        "post a message",
        "post to slack",
        "reply in slack",
        "reply to thread",
        "post a comment",
        "add a comment",
        "comment on issue",
        "comment on pull request"
    ]

    private static let followUpActionTerms = [
        "remind me",
        "set reminder",
        "schedule a reminder",
        "schedule follow-up",
        "schedule follow up",
        "check back",
        "keep an eye on",
        "notify me",
        "wake me",
        "watch this",
        "monitor this"
    ]

    private static let shellActionTerms = [
        "run ",
        "execute ",
        "restart",
        "rebuild",
        "build ",
        "install ",
        "download ",
        "test this",
        "run tests",
        "swift test",
        "npm ",
        "pnpm ",
        "yarn ",
        "git ",
        "debug "
    ]

    private static let workspaceFileActionTerms = [
        "read ",
        "open ",
        "inspect ",
        "review ",
        "summarize ",
        "look at ",
        "check "
    ]

    private static let workspaceFileReferenceTerms = [
        " file",
        " folder",
        " workspace",
        "readme",
        "package.swift",
        "plan.md",
        ".swift",
        ".md",
        ".json",
        ".yaml",
        ".yml",
        ".txt",
        ".py",
        ".ts",
        ".tsx",
        ".js",
        ".jsx"
    ]

    private static let explicitFileMutationTerms = [
        "create file",
        "create a file",
        "write file",
        "write a file",
        "edit file",
        "edit the file",
        "modify file",
        "modify the file",
        "update file",
        "update the file",
        "change file",
        "change the file",
        "patch ",
        "apply patch",
        "delete file",
        "delete the file",
        "fix the code",
        "commit ",
        "push "
    ]

    private static let fileMutationActionTerms = [
        "create ",
        "write ",
        "edit ",
        "modify ",
        "update ",
        "change ",
        "patch ",
        "delete ",
        "fix "
    ]
}
