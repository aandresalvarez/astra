import Foundation
import ASTRAModels

enum TaskExecutionGitRequirementResolver {
    static func approvedPlanIntent(_ plan: TaskPlanPayload, mode: TaskPlanExecutionMode) -> String {
        let steps = mode == .nextStep ? TaskPlanService.nextExecutableStep(in: plan).map { [$0] } ?? [] : plan.steps
        let context = mode == .fullPlan ? [plan.title, plan.goal] : []
        return (["Approved plan execution:"] + context + steps.flatMap {
            [$0.title, $0.detail, $0.doneSignal] + $0.likelyTools
        }).joined(separator: "\n")
    }

    static func resolve(task: AgentTask, acceptedTurn: String?, writable: Bool) -> TaskExecutionResourceScope.GitAccess {
        let prefix = "ASTRA_GIT_ACCESS="
        let declarations = task.constraints.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard declarations.allSatisfy({ ["read_only", "read_write"].contains($0) }),
              Set(declarations).count <= 1 else { return .invalid }
        let workflowWrites = task.isolationStrategy == .gitBranch || task.validationStrategy == .runTests
        if declarations.first == "read_only" { return workflowWrites ? .invalid : .readOnly }
        if declarations.first == "read_write" { return writable ? .readWrite : .invalid }
        guard writable else { return .readOnly }
        let intent = acceptedTurn.flatMap { $0.isEmpty ? nil : $0 } ?? [task.title, task.goal].joined(separator: "\n")
        return workflowWrites || mutationHint(in: intent) ? .readWrite : .readOnly
    }

    /// Compatibility hints for unstructured turns, not a command permission.
    /// Explicit declarations and workflow requirements own the captured decision.
    static func mutationHint(in text: String) -> Bool {
        let git = #"\bgit(?:\s+(?:(?:-C|-c|--git-dir|--work-tree)(?:=|\s+)(?:'[^']*'|"[^"]*"|\S+)|--no-optional-locks))*\s+"#
        for line in text.components(separatedBy: CharacterSet(charactersIn: "\n;")) {
            if line.range(of: #"\b(?:do not|don't|never|avoid|without)\b.*\b(?:commit|push|pull|git)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if line.range(of: git + #"(?:fetch|pull|push|clone|add|commit|checkout|switch|restore|reset|clean|merge|rebase|cherry-pick|revert|stash|update-ref|gc|maintenance|submodule\s+update|remote\s+(?:add|remove|rename|set-url|update))\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { return true }
            if line.range(of: #"\bgh\s+pr\s+checkout\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            for command in ["branch", "tag", "config", "worktree"] {
                guard let match = line.range(of: git + command + #"\b"#, options: [.regularExpression, .caseInsensitive]) else { continue }
                let tail = line[match.upperBound...].prefix { !["&", "`"].contains($0) }
                let arguments = tail.split(whereSeparator: \.isWhitespace).map(String.init)
                if ambiguousCommandWrites(command, arguments: arguments) { return true }
            }
            if line.range(of: #"\b(?:commit(?:\s+(?:your|the|these|this|all|my|our))?\s+(?:changes?|fix(?:es)?|work)|(?:make|create)\s+(?:a|the)\s+commit|create\s+a\s+branch|push\s+(?:to\s+github|changes)|pull\s+(?:the\s+)?latest|sync\s+with\s+origin)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { return true }
        }
        return false
    }

    private static func ambiguousCommandWrites(_ command: String, arguments: [String]) -> Bool {
        switch command {
        case "branch", "tag":
            if arguments.isEmpty { return false }
            let readFlags: Set<String> = ["--show-current", "--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format"]
            return !arguments.allSatisfy { argument in
                readFlags.contains(argument) || argument.hasPrefix("--format=") || argument.hasPrefix("--sort=")
            }
        case "worktree":
            return arguments.first != "list"
        case "config":
            if arguments.contains(where: { ["--unset", "--unset-all", "--add", "--replace-all", "--remove-section", "--rename-section", "--edit", "-e", "set", "unset", "edit", "rename-section", "remove-section"].contains($0) }) { return true }
            if arguments.contains(where: { ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "get", "list"].contains($0) }) { return false }
            return arguments.filter { !$0.hasPrefix("-") }.count > 1
        default:
            return true
        }
    }
}
