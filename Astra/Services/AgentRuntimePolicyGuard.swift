import Foundation
import ASTRACore

struct AgentRuntimePolicyViolation: Equatable, Sendable {
    var reason: String
    var toolName: String?
    var detail: String?
    var requiresApproval: Bool = false
    var approvalGrant: String?

    var userMessage: String {
        let tool = toolName.map { " Tool: \($0)." } ?? ""
        let detailText = detail.map { " Detail: \($0)" } ?? ""
        let grantText = approvalGrant.map { " Runtime grant: \($0)" } ?? ""
        if requiresApproval {
            let requestedTool = toolName ?? "unknown"
            return "Permission requested for tool: \(requestedTool). ASTRA paused the provider because observed activity requires user approval. \(reason).\(tool)\(detailText)\(grantText)"
        }
        return "ASTRA stopped the provider because observed activity violated the run policy. \(reason).\(tool)\(detailText)"
    }
}

struct AgentRuntimePolicyGuard: Sendable {
    private let manifest: RunPermissionManifest
    private let allowedPathRoots: [String]

    init(manifest: RunPermissionManifest) {
        self.manifest = manifest
        let roots = [manifest.workspacePath] + manifest.additionalPaths
        self.allowedPathRoots = roots
            .map(Self.standardizedAbsolutePath)
            .filter { !$0.isEmpty }
    }

    func violation(for parsed: ParsedEvent) -> AgentRuntimePolicyViolation? {
        guard !manifest.providerRender.usesBroadProviderPermissions,
              let observed = ProviderPolicyAdapterRegistry
                .adapter(for: manifest.providerID)
                .observedEvent(from: parsed) else {
            return nil
        }

        switch observed.kind {
        case .toolUse, .fileChange, .networkAccess:
            return validateObservedAction(observed)
        case .toolResult, .deniedAction:
            return nil
        }
    }

    private func validateObservedAction(_ observed: PolicyObservedEvent) -> AgentRuntimePolicyViolation? {
        guard let toolName = observed.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolName.isEmpty else {
            return AgentRuntimePolicyViolation(reason: "The provider reported an unnamed tool use", toolName: nil, detail: observed.summary)
        }

        if toolMatches(toolName, command: observed.command, candidates: manifest.providerRender.deniedTools) {
            return AgentRuntimePolicyViolation(
                reason: "The tool is explicitly denied by the effective ASTRA policy",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if requiresApproval(toolName: toolName, command: observed.command) {
            return AgentRuntimePolicyViolation(
                reason: "The tool or command is configured as ask-first by the effective ASTRA policy",
                toolName: toolName,
                detail: observed.summary,
                requiresApproval: true,
                approvalGrant: suggestedApprovalGrant(toolName: toolName, command: observed.command)
            )
        }

        if !toolMatches(toolName, command: observed.command, candidates: manifest.providerRender.allowedTools) {
            return AgentRuntimePolicyViolation(
                reason: "The tool is not in the provider allow-list for this run",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if (isShellTool(toolName) || (observed.command != nil && !isFileTool(toolName) && !isNetworkTool(toolName))),
           let violation = validateShell(command: observed.command, toolName: toolName) {
            return violation
        }

        if isFileTool(toolName),
           let violation = validateFilePath(observed.path, toolName: toolName, summary: observed.summary, requiresPath: isMutationTool(toolName)) {
            return violation
        }

        if isMutationTool(toolName),
           let violation = validateFilePath(observed.path, toolName: toolName, summary: observed.summary, requiresPath: true) {
            return violation
        }

        if isNetworkTool(toolName) || observed.url != nil || observed.command?.lowercased().contains("curl ") == true,
           let violation = validateNetwork(url: observed.url ?? observed.command.flatMap(Self.firstURL(in:)), toolName: toolName) {
            return violation
        }

        return nil
    }

    private func validateShell(command: String?, toolName: String) -> AgentRuntimePolicyViolation? {
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if manifest.providerRender.deniedShellPatterns.contains("*") {
            return AgentRuntimePolicyViolation(
                reason: "Shell execution is denied by the effective ASTRA policy",
                toolName: toolName,
                detail: trimmedCommand.isEmpty ? nil : trimmedCommand
            )
        }

        guard !trimmedCommand.isEmpty else {
            if manifest.providerRender.deniedShellPatterns.isEmpty,
               manifest.providerRender.allowedShellPatterns.isEmpty {
                return nil
            }
            return AgentRuntimePolicyViolation(
                reason: "ASTRA could not validate the shell command text reported by the provider",
                toolName: toolName,
                detail: nil
            )
        }

        if matchesAnyShellPattern(trimmedCommand, patterns: manifest.providerRender.deniedShellPatterns) {
            return AgentRuntimePolicyViolation(
                reason: "The shell command matches a denied command pattern",
                toolName: toolName,
                detail: trimmedCommand
            )
        }

        let allowedShellPatterns = manifest.providerRender.allowedShellPatterns
        if !allowedShellPatterns.isEmpty,
           !allowedShellPatterns.contains("*"),
           !matchesAnyShellPattern(trimmedCommand, patterns: allowedShellPatterns),
           !toolPatternAllowsShellCommand(trimmedCommand) {
            if matchesAnyShellPattern(trimmedCommand, patterns: manifest.providerRender.askFirstShellPatterns) {
                return AgentRuntimePolicyViolation(
                    reason: "The shell command requires user approval by the effective ASTRA policy",
                    toolName: toolName,
                    detail: trimmedCommand,
                    requiresApproval: true,
                    approvalGrant: suggestedApprovalGrant(toolName: toolName, command: trimmedCommand)
                )
            }
            return AgentRuntimePolicyViolation(
                reason: "The shell command is outside the allowed command patterns for this run",
                toolName: toolName,
                detail: trimmedCommand
            )
        }

        return nil
    }

    private func validateFilePath(
        _ path: String?,
        toolName: String,
        summary: String?,
        requiresPath: Bool
    ) -> AgentRuntimePolicyViolation? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            guard requiresPath else { return nil }
            return AgentRuntimePolicyViolation(
                reason: "ASTRA could not validate the file path for a mutating tool",
                toolName: toolName,
                detail: summary
            )
        }
        guard isPathInScope(path) else {
            return AgentRuntimePolicyViolation(
                reason: "The file path is outside the workspace paths allowed for this run",
                toolName: toolName,
                detail: path
            )
        }
        return nil
    }

    private func validateNetwork(url: String?, toolName: String) -> AgentRuntimePolicyViolation? {
        if manifest.providerRender.deniedURLPatterns.contains("*") {
            return AgentRuntimePolicyViolation(
                reason: "Network access is denied by the effective ASTRA policy",
                toolName: toolName,
                detail: url
            )
        }

        let allowedURLPatterns = manifest.providerRender.allowedURLPatterns
        guard !allowedURLPatterns.isEmpty, !allowedURLPatterns.contains("*") else {
            return nil
        }
        guard let url, matchesAnyURLPattern(url, patterns: allowedURLPatterns) else {
            return AgentRuntimePolicyViolation(
                reason: "The network destination is outside the URL allow-list for this run",
                toolName: toolName,
                detail: url
            )
        }
        return nil
    }

    private func isPathInScope(_ rawPath: String) -> Bool {
        let candidate: String
        if rawPath.hasPrefix("/") {
            candidate = Self.standardizedAbsolutePath(rawPath)
        } else {
            candidate = Self.standardizedAbsolutePath((manifest.workspacePath as NSString).appendingPathComponent(rawPath))
        }

        return allowedPathRoots.contains { root in
            candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    private func requiresApproval(toolName: String, command: String?) -> Bool {
        if let command,
           isShellTool(toolName),
           (manifest.providerRender.deniedShellPatterns.contains("*")
            || matchesAnyShellPattern(command, patterns: manifest.providerRender.deniedShellPatterns)) {
            return false
        }
        if let command,
           isShellTool(toolName),
           toolPatternAllowsShellCommand(command) {
            return false
        }
        if toolMatches(toolName, command: command, candidates: manifest.providerRender.askFirstTools) {
            return true
        }
        if let command,
           isShellTool(toolName),
           matchesAnyShellPattern(command, patterns: manifest.providerRender.askFirstShellPatterns) {
            return true
        }
        return false
    }

    private func suggestedApprovalGrant(toolName: String, command: String?) -> String {
        if isShellTool(toolName),
           let commandRoot = Self.shellCommandRoot(command),
           !commandRoot.isEmpty {
            return "Bash(\(commandRoot):*)"
        }
        return Self.canonicalProviderToolName(toolName)
    }

    private func toolMatches(_ tool: String, command: String?, candidates: [String]) -> Bool {
        let normalizedTool = Self.normalizedToolName(tool)
        let command = command?.trimmingCharacters(in: .whitespacesAndNewlines)

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()

            if lower == "*" {
                return true
            }
            if let openParen = lower.firstIndex(of: "("),
               lower.hasSuffix(")") {
                let candidateTool = String(lower[..<openParen])
                let patternStart = lower.index(after: openParen)
                let pattern = String(lower[patternStart..<lower.index(before: lower.endIndex)])
                let normalizedCandidateTool = Self.normalizedToolName(candidateTool)
                if normalizedCandidateTool == normalizedTool {
                    if pattern == "*" { return true }
                    if let command, matchesShellPattern(command, pattern: pattern) {
                        return true
                    }
                }
                if normalizedCandidateTool == "bash",
                   let command,
                   matchesShellPattern(command, pattern: pattern) {
                    return true
                }
                continue
            }

            if Self.normalizedToolName(trimmed) == normalizedTool {
                return true
            }
            if isShellTool(tool), lower.hasPrefix("shell("), let command, matchesShellPermission(command, permission: lower) {
                return true
            }
        }

        return false
    }

    private func toolPatternAllowsShellCommand(_ command: String) -> Bool {
        manifest.providerRender.allowedTools.contains { candidate in
            let lower = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let openParen = lower.firstIndex(of: "("),
                  lower.hasSuffix(")") else {
                return false
            }
            let candidateTool = String(lower[..<openParen])
            guard Self.normalizedToolName(candidateTool) == "bash" else {
                return false
            }
            let patternStart = lower.index(after: openParen)
            let pattern = String(lower[patternStart..<lower.index(before: lower.endIndex)])
            return matchesShellPattern(command, pattern: pattern)
        }
    }

    private func matchesShellPermission(_ command: String, permission: String) -> Bool {
        guard let openParen = permission.firstIndex(of: "("),
              permission.hasSuffix(")") else {
            return false
        }
        let patternStart = permission.index(after: openParen)
        let pattern = String(permission[patternStart..<permission.index(before: permission.endIndex)])
        return matchesShellPattern(command, pattern: pattern)
    }

    private func matchesAnyShellPattern(_ command: String, patterns: [String]) -> Bool {
        patterns.contains { matchesShellPattern(command, pattern: $0) }
    }

    private func matchesShellPattern(_ command: String, pattern: String) -> Bool {
        let normalizedCommand = Self.normalizedShellText(command)
        let normalizedPattern = Self.normalizedShellText(pattern.replacingOccurrences(of: ":", with: " "))
        return Self.wildcardMatch(normalizedCommand, pattern: normalizedPattern)
    }

    private func matchesAnyURLPattern(_ url: String, patterns: [String]) -> Bool {
        let normalized = url.lowercased()
        return patterns.contains { Self.wildcardMatch(normalized, pattern: $0.lowercased()) }
    }

    private func isShellTool(_ tool: String) -> Bool {
        let normalized = Self.normalizedToolName(tool)
        return normalized == "bash" || normalized == "shell"
    }

    private func isMutationTool(_ tool: String) -> Bool {
        ["write", "edit", "multiedit"].contains(Self.normalizedToolName(tool))
    }

    private func isFileTool(_ tool: String) -> Bool {
        ["read", "write", "edit", "multiedit"].contains(Self.normalizedToolName(tool))
    }

    private func isNetworkTool(_ tool: String) -> Bool {
        ["webfetch", "websearch"].contains(Self.normalizedToolName(tool))
    }

    private static func normalizedToolName(_ tool: String) -> String {
        let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "shell":
            return "bash"
        case "multi_edit":
            return "multiedit"
        default:
            return lower
        }
    }

    private static func canonicalProviderToolName(_ tool: String) -> String {
        switch normalizedToolName(tool) {
        case "bash": return "Bash"
        case "read": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write": return "Write"
        case "edit": return "Edit"
        case "multiedit": return "MultiEdit"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return tool.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func shellCommandRoot(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    private static func normalizedShellText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func standardizedAbsolutePath(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }

        var regex = "^"
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            default:
                regex += NSRegularExpression.escapedPattern(for: String(scalar))
            }
        }
        regex += "$"

        guard let compiled = try? NSRegularExpression(pattern: regex) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return compiled.firstMatch(in: value, range: range) != nil
    }

    private static func firstURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"')<>]+"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}
