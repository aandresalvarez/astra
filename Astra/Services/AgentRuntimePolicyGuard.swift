import Foundation
import ASTRACore

struct AgentRuntimePolicyViolation: Equatable, Sendable {
    var reason: String
    var toolName: String?
    var detail: String?

    var userMessage: String {
        let tool = toolName.map { " Tool: \($0)." } ?? ""
        let detailText = detail.map { " Detail: \($0)" } ?? ""
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
           let violation = validateNetwork(urls: networkURLs(from: observed), toolName: toolName) {
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

    private func validateNetwork(urls: [String], toolName: String) -> AgentRuntimePolicyViolation? {
        if manifest.providerRender.deniedURLPatterns.contains("*") {
            return AgentRuntimePolicyViolation(
                reason: "Network access is denied by the effective ASTRA policy",
                toolName: toolName,
                detail: urls.first
            )
        }

        if let deniedURL = urls.first(where: { matchesAnyURLPattern($0, patterns: manifest.providerRender.deniedURLPatterns) }) {
            return AgentRuntimePolicyViolation(
                reason: "The network destination matches a denied URL pattern for this run",
                toolName: toolName,
                detail: deniedURL
            )
        }

        let allowedURLPatterns = manifest.providerRender.allowedURLPatterns
        guard !allowedURLPatterns.isEmpty, !allowedURLPatterns.contains("*") else {
            return nil
        }
        guard !urls.isEmpty,
              urls.allSatisfy({ matchesAnyURLPattern($0, patterns: allowedURLPatterns) }) else {
            return AgentRuntimePolicyViolation(
                reason: "The network destination is outside the URL allow-list for this run",
                toolName: toolName,
                detail: urls.first
            )
        }
        return nil
    }

    private func networkURLs(from observed: PolicyObservedEvent) -> [String] {
        var values: [String] = []
        if let url = observed.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            values.append(url)
        }
        if let command = observed.command {
            values.append(contentsOf: Self.allURLs(in: command))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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

    private static func normalizedShellText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func standardizedAbsolutePath(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return (standardized as NSString).resolvingSymlinksInPath
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
        allURLs(in: text).first
    }

    private static func allURLs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"')<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            return String(text[valueRange])
        }
    }
}
