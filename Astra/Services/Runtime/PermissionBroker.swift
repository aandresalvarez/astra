import Foundation
import ASTRACore

enum PermissionBroker {
    static let brokerVersion = 1

    static func permissionRequest(from observed: PolicyObservedEvent) -> PermissionRequest? {
        guard let toolName = nonEmpty(observed.toolName) else { return nil }
        let command = nonEmpty(observed.command)
        let path = nonEmpty(observed.path)
        let url = nonEmpty(observed.url) ?? command.flatMap(firstURL)

        if isShellTool(toolName), let command {
            return .shell(command: command, toolName: toolName)
        }
        if isMutationTool(toolName), let path {
            return .fileWrite(path: path, toolName: toolName)
        }
        if isNetworkTool(toolName), let url {
            return .network(url: url, toolName: toolName)
        }
        if let command, !isFileTool(toolName), !isNetworkTool(toolName) {
            return .shell(command: command, toolName: toolName)
        }
        return .tool(name: toolName, context: nonEmpty(observed.summary))
    }

    static func providerNativePromptRequest(toolName: String, context: String?) -> PermissionRequest {
        let effectiveTool = nonEmpty(toolName) ?? "ToolApproval"
        if isShellTool(effectiveTool),
           let command = shellCommandHint(toolName: effectiveTool, context: context) {
            return .shell(command: command, toolName: effectiveTool)
        }
        return .providerNativePrompt(toolName: effectiveTool, context: nonEmpty(context))
    }

    static func approvalGrants(for request: PermissionRequest) -> [PermissionGrant] {
        sanitizeGrants(rawApprovalGrants(for: request))
    }

    static func approvalPayloadString(
        providerID: AgentRuntimeID,
        request: PermissionRequest,
        reason: String,
        providerDetail: String? = nil,
        grants: [PermissionGrant],
        requestID: String? = nil
    ) -> String {
        let payload = approvalPayload(
            providerID: providerID,
            request: request,
            reason: reason,
            providerDetail: providerDetail,
            grants: grants,
            requestID: requestID
        )
        return TaskEvent.payloadString(
            payload,
            fallback: payload.displayMessage,
            encoder: TaskEventPayloadCodec.makeUnescapedEncoder()
        )
    }

    static func approvalPayload(
        providerID: AgentRuntimeID,
        request: PermissionRequest,
        reason: String,
        providerDetail: String? = nil,
        grants: [PermissionGrant],
        requestID: String? = nil
    ) -> PermissionApprovalEventPayload {
        let grants = sanitizeGrants(grants)
        let message = approvalMessage(
            providerID: providerID,
            request: request,
            reason: reason,
            providerDetail: providerDetail,
            grants: grants
        )
        let decision = PermissionDecision.askUser(message: message, grants: grants)
        return PermissionApprovalEventPayload(
            brokerVersion: brokerVersion,
            providerID: providerID,
            request: request,
            decision: decision,
            grants: grants,
            displayMessage: message,
            requestID: requestID
        )
    }

    static func displayMessage(from payload: String) -> String {
        PermissionApprovalEventPayload.decoded(from: payload)?.displayMessage ?? payload
    }

    static func structuredApprovalGrants(from payload: String) -> [PermissionGrant] {
        guard let decoded = PermissionApprovalEventPayload.decoded(from: payload) else {
            return []
        }
        let requestGrants = approvalGrants(for: decoded.request)
        guard !requestGrants.isEmpty else { return [] }
        return requestGrants
    }

    static func legacyApprovalGrants(from payload: String) -> [PermissionGrant] {
        let patterns = [
            #"Runtime grant:\s*([^\n]+)"#,
            #""grant"\s*:\s*"([^"]+)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: payload, range: NSRange(payload.startIndex..., in: payload)),
                  let range = Range(match.range(at: 1), in: payload) else {
                continue
            }
            let value = String(payload[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let grant = permissionGrant(fromProviderString: value) {
                return [grant]
            }
        }
        return []
    }

    static func sanitizeApprovedGrants(_ grants: [PermissionGrant]) -> [PermissionGrant] {
        sanitizeGrants(grants)
    }

    static func taskScopedApprovalGrants(for grants: [PermissionGrant]) -> [PermissionGrant] {
        let sanitized = sanitizeGrants(grants)
        guard sanitized.allSatisfy(isReusableForTaskScope) else { return [] }
        return sanitized
    }

    static func permissionGrant(fromProviderString value: String) -> PermissionGrant? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let shellGrant = shellGrant(fromProviderString: trimmed) {
            return shellGrant
        }
        guard isSafeToolGrantName(trimmed) else { return nil }
        return .providerTool(name: canonicalProviderToolName(trimmed))
    }

    static func providerGrantStrings(for grants: [PermissionGrant], runtime: AgentRuntimeID) -> [String] {
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime)
        return uniqueProviderGrantStrings(adapter.providerGrantStrings(for: sanitizeGrants(grants)))
            .filter(isSafeProviderGrantString)
    }

    static func providerRuntimeGrantStrings(for grants: [PermissionGrant], runtime: AgentRuntimeID) -> [String] {
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime)
        return uniqueProviderGrantStrings(adapter.providerRuntimeGrantStrings(for: sanitizeGrants(grants)))
            .filter(isSafeProviderGrantString)
    }

    static func executionPolicy(forRuntime runtime: AgentRuntimeID, grants: [PermissionGrant]) -> AgentRuntimeExecutionPolicy {
        let sanitizedGrants = sanitizeGrants(grants)
        let providerGrants = providerGrantStrings(for: sanitizedGrants, runtime: runtime)
        let allowedTools = Array(Set(AgentPolicy.preset(.review).allowedTools + providerGrants)).sorted()
        return .approvedRuntimePermission(
            runtime: runtime,
            allowedTools: allowedTools,
            grants: sanitizedGrants
        )
    }

    static func resumeMessage(
        providerID: AgentRuntimeID,
        grants: [PermissionGrant],
        fallback: String? = nil,
        scopeDescription: String = "one-time runtime permission for this run"
    ) -> String {
        let providerGrants = providerGrantStrings(for: grants, runtime: providerID)
        let grantSummary = providerGrants.first ?? nonEmpty(fallback) ?? "the requested tool"
        let shellGuidance = shellResumeGuidance(for: grants, providerGrants: providerGrants)
        return """
        ASTRA approved \(scopeDescription): \(grantSummary). Continue the original task from where it stopped. Do not ask for another interactive CLI approval for the same operation; use the approved provider permissions for this run.\(shellGuidance)
        """
    }

    static func uniqueProviderGrantStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result.sorted()
    }

    private static func rawApprovalGrants(for request: PermissionRequest) -> [PermissionGrant] {
        switch request {
        case .tool(let name, let context):
            if isLocalBrowserApprovalTool(normalizedToolName(name)) {
                return browserApprovalGrants(action: name, context: context)
            }
            return safeProviderToolGrant(name).map { [$0] } ?? []
        case .shell(let command, _):
            return shellApprovalGrants(command: command)
        case .fileWrite(let path, let toolName):
            var grants: [PermissionGrant] = [
                .filePath(path: path, access: "write")
            ]
            if let providerGrant = safeProviderToolGrant(toolName ?? "Write") {
                grants.append(providerGrant)
            } else if let providerGrant = safeProviderToolGrant("Write") {
                grants.append(providerGrant)
            }
            return grants
        case .network(let url, let toolName):
            var grants: [PermissionGrant] = []
            if let pattern = networkApprovalPattern(for: url) {
                grants.append(.networkPattern(pattern: pattern))
            }
            if let providerGrant = toolName.flatMap(safeProviderToolGrant) {
                grants.append(providerGrant)
            } else if let providerGrant = safeProviderToolGrant("WebFetch") {
                grants.append(providerGrant)
            }
            return grants
        case .credential:
            return []
        case .providerNativePrompt(let toolName, let context):
            if isShellTool(toolName),
               let command = shellCommandHint(toolName: toolName, context: context) {
                return shellApprovalGrants(command: command)
            }
            return safeProviderToolGrant(toolName).map { [$0] } ?? []
        }
    }

    private static func approvalMessage(
        providerID: AgentRuntimeID,
        request: PermissionRequest,
        reason: String,
        providerDetail: String?,
        grants: [PermissionGrant]
    ) -> String {
        let tool = toolName(for: request)
        let detail = detail(for: request)
        let providerGrants = providerGrantStrings(for: grants, runtime: providerID)
        var lines = [
            "Permission requested for tool: \(tool). ASTRA paused before allowing this run to continue.",
            "What ASTRA observed: \(observedActionDescription(toolName: tool, detail: detail))",
            "Why approval is needed: \(sentence(reason))",
            "What allowing does: \(approvalEffectDescription(providerGrants: providerGrants))",
            "What to check: \(decisionGuidance(toolName: tool, detail: detail))"
        ]
        if let detail, !detail.isEmpty {
            lines.append("Detail: \(detail)")
        }
        if let grant = providerGrants.first {
            lines.append("Runtime grant: \(grant)")
        }
        if let providerDetail = nonEmpty(providerDetail) {
            lines.append("Provider detail: \(providerDetail)")
        }
        return lines.joined(separator: "\n")
    }

    private static func toolName(for request: PermissionRequest) -> String {
        switch request {
        case .tool(let name, _):
            name
        case .shell(_, let toolName):
            toolName ?? "Bash"
        case .fileWrite(_, let toolName):
            toolName ?? "Write"
        case .network(_, let toolName):
            toolName ?? "WebFetch"
        case .credential(let label):
            label
        case .providerNativePrompt(let toolName, _):
            toolName
        }
    }

    private static func detail(for request: PermissionRequest) -> String? {
        switch request {
        case .tool(_, let context), .providerNativePrompt(_, let context):
            context
        case .shell(let command, _):
            command
        case .fileWrite(let path, _):
            path
        case .network(let url, _):
            url
        case .credential(let label):
            label
        }
    }

    private static func observedActionDescription(toolName: String, detail: String?) -> String {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTool = normalizedToolName(toolName)
        guard !trimmedDetail.isEmpty else {
            return "\(toolName) request from the provider"
        }
        if normalizedTool == "bash" {
            return "Bash command: \(trimmedDetail)"
        }
        if ["read", "write", "edit", "multiedit"].contains(normalizedTool) {
            return "\(toolName) path: \(trimmedDetail)"
        }
        if ["webfetch", "websearch"].contains(normalizedTool) {
            return "\(toolName) destination: \(trimmedDetail)"
        }
        return "\(toolName) request: \(trimmedDetail)"
    }

    private static func approvalEffectDescription(providerGrants: [String]) -> String {
        guard let grant = providerGrants.first else {
            return "Grants this provider request one time for this run, then restarts the provider from the stopped point."
        }
        return "Grants \(grant) one time for this run, then restarts the provider from the stopped point."
    }

    private static func decisionGuidance(toolName: String, detail: String?) -> String {
        let normalizedTool = normalizedToolName(toolName)
        let root = shellCommandRoot(detail)?.lowercased()
        if normalizedTool == "bash" {
            switch root {
            case "bq":
                return "Allow only if this BigQuery command matches the task and should use the signed-in Google Cloud account and project."
            case "gcloud":
                return "Allow only if this Google Cloud command matches the task and should use the signed-in Google Cloud account and project."
            case "curl", "wget":
                return "Allow only if contacting that network destination is expected for this task."
            default:
                return "Allow only if this shell command matches the task; it will run locally with this run's environment and credentials."
            }
        }

        switch normalizedTool {
        case "read":
            return "Allow only if the provider should read that path for this task."
        case "write", "edit", "multiedit":
            return "Allow only if the provider should change that path for this task."
        case "webfetch", "websearch":
            return "Allow only if that web or network access is expected for this task."
        default:
            return "Allow only if this action matches the task and the requested access is expected."
        }
    }

    private static func safeProviderToolGrant(_ name: String) -> PermissionGrant? {
        let canonical = canonicalProviderToolName(name)
        guard isSafeToolGrantName(canonical) else { return nil }
        return .providerTool(name: canonical)
    }

    private static func networkApprovalPattern(for rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func shellApprovalGrants(command: String?) -> [PermissionGrant] {
        guard let command else { return [] }
        let segments = actionableShellSegments(command).filter { !isBenignShellSetupSegment($0) }
        var grants: [PermissionGrant] = []
        for segment in segments {
            guard let grant = ShellCommandRiskClassifier.approvalGrant(forShellSegment: segment),
                  isSafeGrant(grant) else {
                continue
            }
            grants.append(grant)
        }
        return sanitizeGrants(grants)
    }

    private static func shellGrant(fromProviderString value: String) -> PermissionGrant? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard (lower.hasPrefix("bash(") || lower.hasPrefix("shell(")),
              trimmed.hasSuffix(")"),
              let openParen = trimmed.firstIndex(of: "(") else {
            return nil
        }
        let bodyStart = trimmed.index(after: openParen)
        let body = String(trimmed[bodyStart..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBroadShellBody(body) else { return nil }

        let executable: String
        let pattern: String
        let firstWhitespace = body.firstIndex(where: { $0.isWhitespace })
        if let colon = body.firstIndex(of: ":"),
           firstWhitespace.map({ colon < $0 }) ?? true {
            executable = String(body[..<colon])
            pattern = String(body[body.index(after: colon)...])
        } else if let split = firstWhitespace {
            executable = String(body[..<split])
            pattern = String(body[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            executable = body
            pattern = "*"
        }
        let grant = PermissionGrant.shellCommand(executable: executable, pattern: pattern)
        return isSafeGrant(grant) ? grant : nil
    }

    private static func sanitizeGrants(_ grants: [PermissionGrant]) -> [PermissionGrant] {
        var seen = Set<PermissionGrant>()
        var result: [PermissionGrant] = []
        for grant in grants where isSafeGrant(grant) {
            guard seen.insert(grant).inserted else { continue }
            result.append(grant)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    private static func isSafeGrant(_ grant: PermissionGrant) -> Bool {
        switch grant {
        case .tool(let name), .providerTool(let name):
            return isSafeToolGrantName(name)
        case .shellCommand(let executable, let pattern):
            let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty,
                  executable != "*",
                  !isUnsafeShellGrantRoot(executable),
                  executable.rangeOfCharacter(from: grantMetacharacters) == nil,
                  pattern.isEmpty == false,
                  !isOverbroadShellGrant(executable: executable, pattern: pattern),
                  pattern.rangeOfCharacter(from: grantMetacharacters) == nil else {
                return false
            }
            return true
        case .filePath(let path, let access):
            return nonEmpty(path) != nil && nonEmpty(access) != nil
        case .networkPattern(let pattern):
            return nonEmpty(pattern) != nil
        case .browserAction(let action, let target):
            return isSafeBrowserActionGrant(action: action, target: target)
        }
    }

    private static func isReusableForTaskScope(_ grant: PermissionGrant) -> Bool {
        switch grant {
        case .shellCommand:
            return ShellCommandRiskClassifier.allowsTaskScopedReuse(grant)
        case .browserAction:
            return false
        default:
            return true
        }
    }

    private static func browserApprovalGrants(action: String, context: String?) -> [PermissionGrant] {
        let normalizedAction = normalizedToolName(action)
        guard isLocalBrowserApprovalTool(normalizedAction),
              let target = nonEmpty(context),
              isSafeBrowserActionGrant(action: normalizedAction, target: target) else {
            return []
        }
        return [.browserAction(action: normalizedAction, target: target)]
    }

    private static func isSafeBrowserActionGrant(action: String, target: String) -> Bool {
        let action = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalBrowserApprovalTool(action),
              !target.isEmpty,
              target.count <= 500,
              action.rangeOfCharacter(from: grantMetacharacters) == nil,
              target.rangeOfCharacter(from: browserGrantRejectedCharacters) == nil else {
            return false
        }
        return true
    }

    private static func isLocalBrowserApprovalTool(_ action: String) -> Bool {
        switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "browser.click", "browser.type":
            return true
        default:
            return false
        }
    }

    private static var browserGrantRejectedCharacters: CharacterSet {
        CharacterSet(charactersIn: "\n\r")
    }

    private static func isSafeToolGrantName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty,
              isKnownProviderGrantTool(trimmed),
              lower != "bash",
              lower != "shell",
              lower != "bash(*)",
              lower != "shell(*)",
              !lower.hasPrefix("bash("),
              !lower.hasPrefix("shell("),
              trimmed.rangeOfCharacter(from: grantMetacharacters) == nil else {
            return false
        }
        return true
    }

    private static func isKnownProviderGrantTool(_ name: String) -> Bool {
        switch normalizedToolName(name) {
        case "read", "grep", "glob", "write", "edit", "multiedit", "webfetch", "websearch", "agent":
            return true
        default:
            return false
        }
    }

    private static func isSafeProviderGrantString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shellGrant = shellGrant(fromProviderString: trimmed) {
            return isSafeGrant(shellGrant)
        }
        return isSafeToolGrantName(trimmed)
    }

    private static func isBroadShellBody(_ body: String) -> Bool {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "*" || normalized == ":*" || normalized.hasPrefix("*:")
    }

    private static func isOverbroadShellGrant(executable: String, pattern: String) -> Bool {
        ShellCommandRiskClassifier.isOverbroadGrant(executable: executable, pattern: pattern)
    }

    private static var grantMetacharacters: CharacterSet {
        CharacterSet(charactersIn: "\n\r;&|`$<>\\")
    }

    private static func canonicalProviderToolName(_ tool: String) -> String {
        switch normalizedToolName(tool) {
        case "read": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write", "create", "apply_patch": return "Write"
        case "edit": return "Edit"
        case "multiedit": return "MultiEdit"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return tool.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func normalizedToolName(_ tool: String) -> String {
        let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("shell(") || lower.hasPrefix("bash(") {
            return "bash"
        }
        switch lower {
        case "shell":
            return "bash"
        case "view":
            return "read"
        case "create", "apply_patch":
            return "write"
        case "multi_edit":
            return "multiedit"
        default:
            return lower
        }
    }

    private static func isShellTool(_ tool: String) -> Bool {
        normalizedToolName(tool) == "bash"
    }

    private static func isMutationTool(_ tool: String) -> Bool {
        ["write", "edit", "multiedit"].contains(normalizedToolName(tool))
    }

    private static func isFileTool(_ tool: String) -> Bool {
        ["read", "write", "edit", "multiedit"].contains(normalizedToolName(tool))
    }

    private static func isNetworkTool(_ tool: String) -> Bool {
        ["webfetch", "websearch"].contains(normalizedToolName(tool))
    }

    private static func shellCommandHint(toolName: String, context: String?) -> String? {
        if let context = nonEmpty(context) {
            if let command = commandHintFromJSONSummary(context) {
                return command
            }
            return context
        }
        return commandHintFromShellPermissionToolName(toolName)
    }

    private static func commandHintFromJSONSummary(_ summary: String) -> String? {
        guard let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["command", "cmd"] {
            if let value = object[key] as? String,
               let command = nonEmpty(value) {
                return command
            }
        }
        return nil
    }

    private static func commandHintFromShellPermissionToolName(_ toolName: String) -> String? {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard (lower.hasPrefix("shell(") || lower.hasPrefix("bash(")),
              trimmed.hasSuffix(")"),
              let openParen = trimmed.firstIndex(of: "(") else {
            return nil
        }
        let patternStart = trimmed.index(after: openParen)
        var hint = String(trimmed[patternStart..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hint.hasSuffix(":*") {
            hint.removeLast(2)
        } else if hint.hasSuffix("*") {
            hint.removeLast()
        }
        hint = hint
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hint.isEmpty ? nil : hint
    }

    private static func shellApprovalRoot(_ root: String) -> String? {
        var normalizedRoot = root
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'({["))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedRoot = normalizedRoot.trimmingCharacters(in: CharacterSet(charactersIn: "\"')}]"))
        guard !normalizedRoot.isEmpty else { return nil }
        if normalizedRoot.hasPrefix("/") {
            normalizedRoot = URL(fileURLWithPath: normalizedRoot).lastPathComponent
        }
        guard normalizedRoot.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r)")) == nil,
              !isUnsafeShellGrantRoot(normalizedRoot) else {
            return nil
        }
        return normalizedRoot
    }

    private static func actionableShellSegments(_ command: String) -> [String] {
        let rawSegments = shellSegmentSeparatorsNormalized(command)
            .split(whereSeparator: { $0.isNewline || $0 == ";" })
            .map(String.init)
        var segments: [String] = []
        for rawSegment in rawSegments {
            appendUnique(normalizedShellText(actionableShellSegment(rawSegment)), to: &segments)
        }
        return segments
    }

    private static func shellSegmentSeparatorsNormalized(_ command: String) -> String {
        let command = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")
        var result = ""
        var index = command.startIndex
        var isInSingleQuote = false
        var isInDoubleQuote = false
        var isEscaped = false

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            let next = nextIndex < command.endIndex ? command[nextIndex] : nil

            if isEscaped {
                result.append(character)
                isEscaped = false
                index = nextIndex
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                index = nextIndex
                continue
            }
            if character == "'", !isInDoubleQuote {
                isInSingleQuote.toggle()
                result.append(character)
                index = nextIndex
                continue
            }
            if character == "\"", !isInSingleQuote {
                isInDoubleQuote.toggle()
                result.append(character)
                index = nextIndex
                continue
            }

            if !isInSingleQuote {
                if character == "$", next == "(" {
                    result.append("\n")
                    index = command.index(after: nextIndex)
                    continue
                }
                if !isInDoubleQuote, (character == "<" || character == ">"), next == "(" {
                    result.append("\n")
                    index = command.index(after: nextIndex)
                    continue
                }
            }

            if !isInSingleQuote, !isInDoubleQuote {
                if character == "&", next == "&" {
                    result.append("\n")
                    index = command.index(after: nextIndex)
                    continue
                }
                if character == "|", next == "|" {
                    result.append("\n")
                    index = command.index(after: nextIndex)
                    continue
                }
                if character == "|" || character == ";" || character.isNewline || character == "`" {
                    result.append("\n")
                    index = nextIndex
                    continue
                }
            }

            result.append(character)
            index = nextIndex
        }
        return result
    }

    private static func actionableShellSegment(_ segment: String) -> String {
        let uncommented = stripShellComment(from: segment)
        var tokens = uncommented.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let controlWords: Set<String> = [
            "if", "then", "do", "else", "elif", "while", "for", "until", "case", "in",
            "fi", "done", "esac", "time", "command", "builtin", "exec", "!"
        ]
        while let first = tokens.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'({[")).lowercased(),
              controlWords.contains(first) {
            tokens.removeFirst()
        }
        if tokens.first?.lowercased() == "env" {
            tokens.removeFirst()
            while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
                tokens.removeFirst()
            }
        }
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    private static func isBenignShellSetupSegment(_ segment: String) -> Bool {
        let normalized = normalizedShellText(segment)
        guard !normalized.isEmpty else { return true }
        let root = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        if root == "mkdir" {
            let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return tokens.contains("-p") || tokens.contains("--parents")
        }
        if isBenignShellProbeSegment(normalized) {
            return true
        }
        return isBenignShellSetupRoot(root)
    }

    private static func isBenignShellProbeSegment(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 3 else { return false }
        switch Array(tokens.prefix(3)) {
        case ["gh", "auth", "status"]:
            return true
        case ["gcloud", "auth", "list"]:
            return true
        default:
            return false
        }
    }

    private static func shellCommandRoot(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = stripShellComment(from: command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    private static func stripShellComment(from segment: String) -> String {
        var result = ""
        var isInSingleQuote = false
        var isInDoubleQuote = false
        var isEscaped = false
        var previous: Character?

        for character in segment {
            if isEscaped {
                result.append(character)
                isEscaped = false
                previous = character
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                previous = character
                continue
            }
            if character == "'", !isInDoubleQuote {
                isInSingleQuote.toggle()
                result.append(character)
                previous = character
                continue
            }
            if character == "\"", !isInSingleQuote {
                isInDoubleQuote.toggle()
                result.append(character)
                previous = character
                continue
            }
            if character == "#",
               !isInSingleQuote,
               !isInDoubleQuote,
               (previous == nil || previous?.isWhitespace == true) {
                break
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func isUnsafeShellGrantRoot(_ root: String) -> Bool {
        var normalized = root.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("/") {
            normalized = URL(fileURLWithPath: normalized).lastPathComponent
        }
        return normalized.hasPrefix("#")
            || isBenignShellSetupRoot(normalized)
            || shellControlWords.contains(normalized)
    }

    private static func isBenignShellSetupRoot(_ root: String) -> Bool {
        [
            "set", "cd", "pwd", "true", "false", ":", "export", "unset", "umask", "read",
            "dirname", "echo", "printf", "test", "[", "]", "exit", "return"
        ].contains(root)
    }

    private static let shellControlWords: Set<String> = [
        "if", "then", "do", "else", "elif", "while", "for", "until", "case", "in",
        "fi", "done", "esac", "time", "command", "builtin", "exec", "!"
    ]

    private static func shellResumeGuidance(for grants: [PermissionGrant], providerGrants: [String]) -> String {
        let shellExecutables = grants.compactMap { grant -> String? in
            if case .shellCommand(let executable, _) = grant {
                return executable
            }
            return nil
        }
        guard !shellExecutables.isEmpty else { return "" }
        let providerGrantSummary = providerGrants.isEmpty
            ? "the approved shell grant"
            : providerGrants.joined(separator: ", ")
        let executableSummary = shellExecutables.joined(separator: ", ")
        return " The shell approval is scoped to \(providerGrantSummary). Start shell calls with the approved executable (\(executableSummary)) instead of wrapping it in setup commands, comments, or echo/if scaffolding that the provider may classify as a new command. For read/list commands, do not redirect output to a file; run the approved command directly and summarize stdout unless a separate file-write permission was approved."
    }

    private static func normalizedShellText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
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

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The effective ASTRA policy requires user approval." }
        guard let last = trimmed.last, ".!?".contains(last) else {
            return "\(trimmed)."
        }
        return trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }
}
