import Foundation
import ASTRACore

struct AgentRuntimePolicyViolation: Equatable, Sendable {
    var reason: String
    var toolName: String?
    var detail: String?
    var violationCategory: String = "runtime_policy"
    var requiresApproval: Bool = false
    var permissionRequest: PermissionRequest?
    var approvalGrants: [PermissionGrant] = []

    /// The grant a person reads: the pattern, not the digest that binds it
    /// to this command's content.
    var approvalGrant: String? {
        approvalGrants.first { !ShellCommandRiskClassifier.isContentGrant($0) }?.displayName
    }

    var userMessage: String {
        if requiresApproval {
            let requestedTool = toolName ?? "unknown"
            let approvalGrant = approvalGrant
            var lines = [
                "Permission requested for tool: \(requestedTool). ASTRA paused before allowing this run to continue.",
                "What ASTRA observed: \(Self.observedActionDescription(toolName: requestedTool, detail: detail))",
                "Why approval is needed: \(Self.sentence(reason))",
                "What allowing does: \(Self.approvalEffectDescription(grant: approvalGrant))",
                "What to check: \(Self.decisionGuidance(toolName: requestedTool, detail: detail))"
            ]
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Detail: \(detail)")
            }
            if let approvalGrant, !approvalGrant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Runtime grant: \(approvalGrant)")
            }
            return lines.joined(separator: "\n")
        }
        let tool = toolName.map { " Tool: \($0)." } ?? ""
        let detailText = detail.map { " Detail: \($0)" } ?? ""
        return "ASTRA stopped the provider because observed activity violated the run policy. \(reason).\(tool)\(detailText)"
    }

    private static func observedActionDescription(toolName: String, detail: String?) -> String {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedDetail.isEmpty else {
            return "\(toolName) request from the provider"
        }
        if normalizedTool == "bash" || normalizedTool == "shell" {
            return "Bash command: \(trimmedDetail)"
        }
        if ["read", "view", "write", "create", "edit", "multiedit", "apply_patch"].contains(normalizedTool) {
            return "\(toolName) path: \(trimmedDetail)"
        }
        if ["webfetch", "websearch"].contains(normalizedTool) {
            return "\(toolName) destination: \(trimmedDetail)"
        }
        return "\(toolName) request: \(trimmedDetail)"
    }

    private static func approvalEffectDescription(grant: String?) -> String {
        let trimmedGrant = grant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedGrant.isEmpty else {
            return "Grants this provider request one time for this run, then restarts the provider from the stopped point."
        }
        return "Grants \(trimmedGrant) one time for this run, then restarts the provider from the stopped point."
    }

    private static func decisionGuidance(toolName: String, detail: String?) -> String {
        let normalizedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let root = shellCommandRoot(detail)?.lowercased()

        if normalizedTool == "bash" || normalizedTool == "shell" {
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
        case "read", "view":
            return "Allow only if the provider should read that path for this task."
        case "write", "create", "edit", "multiedit", "apply_patch":
            return "Allow only if the provider should change that path for this task."
        case "webfetch", "websearch":
            return "Allow only if that web or network access is expected for this task."
        default:
            return "Allow only if this action matches the task and the requested access is expected."
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The effective ASTRA policy requires user approval." }
        guard let last = trimmed.last, ".!?".contains(last) else {
            return "\(trimmed)."
        }
        return trimmed
    }

    private static func shellCommandRoot(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }
}

struct AgentRuntimePolicyGuard: Sendable {
    private let manifest: RunPermissionManifest
    private let boundary: RunBoundary

    var providerID: AgentRuntimeID {
        manifest.providerID
    }

    var usesBroadProviderPermissions: Bool {
        manifest.providerRender.usesBroadProviderPermissions
    }

    init(
        manifest: RunPermissionManifest,
        pathMapper: ExecutionEnvironmentPathMapper? = nil,
        homeDirectories: [String] = [NSHomeDirectory()]
    ) {
        self.init(
            manifest: manifest,
            boundary: RunBoundary(
                manifest: manifest,
                pathMapper: pathMapper,
                homeDirectories: homeDirectories
            )
        )
    }

    init(manifest: RunPermissionManifest, boundary: RunBoundary) {
        self.manifest = manifest
        self.boundary = boundary
    }

    func hasAppliedApprovalGrants(_ grants: [PermissionGrant]) -> Bool {
        let requested = Set(PermissionBroker.sanitizeApprovedGrants(grants))
        guard !requested.isEmpty else { return false }
        return requested.isSubset(of: Set(manifest.approvalGrants))
    }

    /// How the effective policy treats a (tool, command) pair, independent of
    /// any provider's own opinion. Lets a live-ask broker apply the *same*
    /// allow/ask/deny rules ASTRA enforces post-hoc — one source of truth, so
    /// auto-approval in Auto mode and the ask card in Ask mode can't drift from
    /// what the guard would have flagged.
    enum CommandDisposition: Equatable {
        case allowed
        case ask
        case denied
    }

    func disposition(
        toolName rawTool: String,
        command rawCommand: String?,
        path rawPath: String? = nil
    ) -> CommandDisposition {
        // Don't special-case an empty tool name: pass it through so
        // validateObservedAction returns its "unnamed tool use" deny, instead
        // of returning .ask here (which Auto would auto-approve — a bypass).
        let toolName = rawTool.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Route through the guard's own post-hoc evaluation so the live
        // decision is identical to what would terminate the run otherwise — no
        // partial reimplementation that could miss allowedShellPatterns,
        // ask-first shell patterns, or the "not in allow-list" deny. A nil
        // violation means the guard would allow; a violation flagged
        // requiresApproval is ask-first; any other violation is a deny the
        // guard would enforce, so it must NOT be auto-approved.
        //
        // The path travels with the tool name for the same reason: without it
        // the live classifier evaluated a *different input* than the post-hoc
        // guard, so a file tool could be waved through live and then flagged
        // out-of-boundary from the stream a moment later. One evaluation, one
        // input.
        let observed = PolicyObservedEvent(
            kind: .toolUse,
            toolName: toolName,
            command: command,
            path: (path?.isEmpty == false) ? path : nil,
            summary: command ?? path
        )
        guard let violation = validateObservedAction(observed, request: nil) else {
            return .allowed
        }
        return violation.requiresApproval ? .ask : .denied
    }

    func violation(for parsed: ParsedEvent) -> AgentRuntimePolicyViolation? {
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: manifest.providerID)
        guard let observed = adapter.observedEvent(from: parsed) else {
            return nil
        }
        if manifest.providerRender.usesBroadProviderPermissions {
            return validateBroadPermissionInvariant(observed)
        }
        let request = adapter.permissionRequest(from: parsed)
            ?? PermissionBroker.permissionRequest(from: observed)
        var browserCommand: String?
        if case .toolUse(let name, _, let input) = parsed, Self.isBrowserBridgeTool(name) {
            browserCommand = Self.browserCommand(fromInput: input)
        }

        switch observed.kind {
        case .toolUse, .fileChange, .networkAccess:
            return validateObservedAction(observed, request: request, browserCommand: browserCommand)
        case .toolResult, .deniedAction:
            return nil
        }
    }

    private func validateBroadPermissionInvariant(
        _ observed: PolicyObservedEvent
    ) -> AgentRuntimePolicyViolation? {
        guard let toolName = observed.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolName.isEmpty else {
            return nil
        }
        if isMutationTool(toolName) {
            return validateTaskOutputMutationOwnership(observed, toolName: toolName)
                ?? validateReadOnlyInputMutation(observed, toolName: toolName)
        }
        // Shell text is intentionally not interpreted here. Every read-only
        // launch resource is enforced by a verified Seatbelt/container boundary
        // before the provider starts. Reconstructing shell semantics in the
        // policy layer created both false positives and an unbounded parser
        // surface; the kernel boundary is the authority.
        return nil
    }

    private func validateObservedAction(
        _ observed: PolicyObservedEvent,
        request: PermissionRequest?,
        browserCommand: String? = nil
    ) -> AgentRuntimePolicyViolation? {
        guard let toolName = observed.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolName.isEmpty else {
            return AgentRuntimePolicyViolation(reason: "The provider reported an unnamed tool use", toolName: nil, detail: observed.summary)
        }

        if let supportTool = runtimeSupportToolDescriptor(for: toolName) {
            if let violation = validateRuntimeSupportTool(supportTool, observed: observed, toolName: toolName) {
                return violation
            }
            if let command = observed.command,
               DockerWorkspaceMCPProjection.canonicalToolName(fromObservedToolName: toolName, runtime: manifest.providerID) != nil {
                return validateWorkspaceShellCommand(command, toolName: toolName)
            }
            return nil
        }

        if isShellTool(toolName),
           let command = observed.command,
           HostControlCLIRelayPolicy.isEnabled(in: manifest.providerRender),
           HostControlCLIRelayPolicy.mentionsRelay(command) {
            guard HostControlCLIRelayPolicy.allows(command) else {
                return AgentRuntimePolicyViolation(
                    reason: "Only an exact typed astra-host-control relay command is allowed",
                    toolName: toolName,
                    detail: observed.summary
                )
            }
            return nil
        }

        if toolMatches(toolName, command: observed.command, candidates: manifest.providerRender.deniedTools) {
            return AgentRuntimePolicyViolation(
                reason: "The tool is explicitly denied by the effective ASTRA policy",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if isShellTool(toolName),
           observed.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           toolMatches(toolName, command: nil, candidates: manifest.providerRender.askFirstTools) {
            return AgentRuntimePolicyViolation(
                reason: "ASTRA could not validate the shell command text for this approval request",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if (isShellTool(toolName) || (observed.command != nil && !isFileTool(toolName) && !isNetworkTool(toolName))),
           let violation = validateDeniedShellCommand(command: observed.command, toolName: toolName) {
            return violation
        }

        if isMutationTool(toolName),
           let violation = validateTaskOutputMutationOwnership(observed, toolName: toolName) {
            return violation
        }

        if isMutationTool(toolName),
           let violation = validateReadOnlyInputMutation(observed, toolName: toolName) {
            return violation
        }

        let matchesAllowedShellPattern = observed.command.map { command in
            isShellTool(toolName)
                && shellCommandAllowedByPatterns(
                    command,
                    patterns: manifest.providerRender.allowedShellPatterns
                )
        } ?? false

        let matchesTaskOutputMutation = matchesTaskOutputFileMutation(observed, toolName: toolName)
        let mutationNeedsScopedApproval = isMutationTool(toolName)
            && toolMatches(toolName, command: nil, candidates: manifest.providerRender.askFirstTools)
            && !matchesTaskOutputMutation
        let matchesProviderAllowedTool = toolMatches(
            toolName,
            command: observed.command,
            candidates: effectiveAllowedToolCandidates,
            shellMatchMode: .allActionableSegments
        )
        let matchesAllowedTool = (matchesProviderAllowedTool && !mutationNeedsScopedApproval)
            || matchesAllowedShellPattern
            || matchesTaskOutputMutation
            || matchesApprovedFileMutationGrant(observed, toolName: toolName)

        if !matchesAllowedTool,
           requiresApproval(toolName: toolName, command: observed.command) {
            return AgentRuntimePolicyViolation(
                reason: "The tool or command is configured as ask-first by the effective ASTRA policy",
                toolName: toolName,
                detail: observed.summary,
                requiresApproval: true,
                permissionRequest: request,
                approvalGrants: request.map(PermissionBroker.approvalGrants) ?? []
            )
        }

        if !matchesAllowedTool {
            return AgentRuntimePolicyViolation(
                reason: "The tool is not in the provider allow-list for this run",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if isPatchMutationTool(toolName),
           let violation = validatePatchMutationPaths(observed, toolName: toolName) {
            return violation
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

        // Last, so every deny above still wins: this only turns an otherwise
        // allowed command that acts outside ASTRA into a question.
        if isShellTool(toolName),
           let command = observed.command,
           let violation = externalCommandApprovalViolation(command: command, toolName: toolName, request: request) {
            return violation
        }
        if Self.isBrowserBridgeTool(toolName),
           let violation = externalBrowserActionApprovalViolation(
               equivalent: browserCommand ?? Self.browserCommand(fromInput: observed.command.map { ["command": $0] }),
               toolName: toolName
           ) {
            return violation
        }

        return nil
    }

    /// Ask and Custom ask before acting outside ASTRA (`ExternalActionPolicy`).
    /// A Custom rule that allows Bash or `git:*` governs local work only: a
    /// command that is not known local work (`LocalShellCommands`) asks
    /// whatever the per-item rules say, and its approval lets it run, so an
    /// approved command is not asked about twice.
    private func externalCommandApprovalViolation(
        command: String,
        toolName: String,
        request: PermissionRequest?
    ) -> AgentRuntimePolicyViolation? {
        guard ExternalActionPolicy.asksUser(for: .agentCommand, level: manifest.policyLevel),
              let pending = unapprovedExternalCommand(command) else {
            return nil
        }
        let request = request ?? PermissionRequest.shell(command: pending, toolName: toolName)
        return AgentRuntimePolicyViolation(
            reason: "The command is not on ASTRA's list of local work, so it asks first at this permission level",
            toolName: toolName,
            detail: command,
            violationCategory: "external_command_requires_approval",
            requiresApproval: true,
            permissionRequest: request,
            approvalGrants: PermissionBroker.approvalGrants(for: request)
        )
    }

    /// The Docker workspace's shell and job tools run a shell command, so the
    /// run's shell rules apply as they do to Bash: a denied pattern refuses it,
    /// and below Auto a command Bash's rules, patterns and approvals do not
    /// allow is asked about — not refused, since in a Docker run this is the
    /// shell — before the external-action gate, approved as a shell command.
    private func validateWorkspaceShellCommand(_ command: String, toolName: String) -> AgentRuntimePolicyViolation? {
        if let denied = validateDeniedShellCommand(command: command, toolName: toolName) { return denied }
        if manifest.policyLevel != .autonomous {
            // As `validateShell`: an allow-list of patterns decides when there
            // is one; otherwise the Bash tool rule (and approvals) does.
            let patterns = manifest.providerRender.allowedShellPatterns
            let allowed = !patterns.isEmpty && !patterns.contains("*")
                ? shellCommandAllowedByPatterns(command, patterns: patterns) || toolPatternAllowsShellCommand(command)
                : toolMatches("Bash", command: command, candidates: effectiveAllowedToolCandidates,
                              shellMatchMode: .allActionableSegments)
            if !allowed {
                let request = PermissionRequest.shell(command: command, toolName: toolName)
                return AgentRuntimePolicyViolation(
                    reason: "The workspace command asks first at this permission level, as Bash would",
                    toolName: toolName,
                    detail: command,
                    requiresApproval: true,
                    permissionRequest: request,
                    approvalGrants: PermissionBroker.approvalGrants(for: request)
                )
            }
        }
        return externalCommandApprovalViolation(command: command, toolName: toolName, request: nil)
    }

    /// The browser MCP tool runs the same bridge commands as `astra-browser`,
    /// so a page change asks at Ask and Custom even when a rule allows the
    /// tool. It is judged, asked about, and approved as that CLI command, its
    /// arguments included, so the card shows what will be changed and one
    /// approved click is not every later click: MCP tools carry no grant of
    /// their own, and one approval then covers both transports.
    private func externalBrowserActionApprovalViolation(
        equivalent: String,
        toolName: String
    ) -> AgentRuntimePolicyViolation? {
        guard ExternalActionPolicy.asksUser(for: .agentCommand, level: manifest.policyLevel),
              let pending = unapprovedExternalCommand(equivalent) else {
            return nil
        }
        let request = PermissionRequest.shell(command: pending, toolName: toolName)
        return AgentRuntimePolicyViolation(
            reason: "The browser action changes a page, which asks first at this permission level",
            toolName: toolName,
            detail: equivalent,
            violationCategory: "external_command_requires_approval",
            requiresApproval: true,
            permissionRequest: request,
            approvalGrants: PermissionBroker.approvalGrants(for: request)
        )
    }

    /// The `astra-browser` command a browser MCP call runs. Read from its
    /// structured `command` and `arguments`, or from the summary the event
    /// recorder made of them (`astra-browser click --selector '…'`), which is
    /// all a provider callback carries. A call whose command cannot be read is
    /// judged as an unregistered command, which counts as a page change.
    static func browserCommand(fromInput input: [String: Any]?) -> String {
        let tool = BrowserBridgeMCPProjection.toolCommand
        if let command = (input?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return ([tool, command] + [browserArgumentWords(input?["arguments"])].compactMap { $0 }).joined(separator: " ")
        }
        if let summary = (input?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           summary.hasPrefix(tool + " ") {
            return summary
        }
        return tool + " unreadable-call"
    }

    /// The MCP tool's `arguments` as the CLI's words, keys sorted:
    /// `--selector 'button.primary'`; a nested value is its JSON.
    static func browserArgumentWords(_ value: Any?) -> String? {
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // The browser MCP server takes CLI-style words, in order
        // (`["--selector", "#delete"]`).
        if let words = value as? [Any], !words.isEmpty {
            return words.map { quoted(($0 as? String) ?? String(describing: $0)) }.joined(separator: " ")
        }
        guard let arguments = value as? [String: Any], !arguments.isEmpty else { return nil }
        return arguments.keys.sorted().map { key -> String in
            let raw = arguments[key]
            let text: String
            switch raw {
            case let string as String:
                text = string
            case let number as NSNumber:
                text = number.stringValue
            default:
                let data = raw.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            return "--\(key) \(quoted(text))"
        }.joined(separator: " ")
    }

    static func isBrowserBridgeTool(_ tool: String) -> Bool {
        let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = BrowserBridgeMCPProjection.toolName
        return lower.contains(BrowserBridgeMCPProjection.serverID) && (lower.hasSuffix(name) || lower.hasSuffix("\(name))"))
    }

    /// The command when it is not known local work and no approval covers
    /// it, or nil. Whether a shell string acts outside this machine cannot be
    /// read in general, so this asks the opposite question
    /// (`LocalShellCommands`): only a command made of listed local tools runs
    /// on a Custom rule alone, and anything else is asked about as written.
    private func unapprovedExternalCommand(_ command: String) -> String? {
        if LocalShellCommands.isLocal(command) || commandApprovedByGrant(command) {
            return nil
        }
        return command
    }

    /// The approval a command is asked for is the set of grants its request
    /// yields, one per command in it (`PermissionBroker`): it runs unasked once
    /// all of them were granted. Comparing grants, not matching patterns,
    /// keeps one approval from standing in for another — a host-scoped read
    /// does not approve a write to that host, a push does not approve a force
    /// — and the same command always finds the approval it was given.
    private func commandApprovedByGrant(_ command: String) -> Bool {
        guard let needed = PermissionBroker.completeShellApprovalGrants(command: command) else { return false }
        return Set(needed).isSubset(of: Set(manifest.approvalGrants))
    }

    private func runtimeSupportToolDescriptor(for toolName: String) -> ProviderRuntimeSupportToolDescriptor? {
        let normalized = Self.normalizedToolName(toolName)
        if let canonicalWorkspaceTool = DockerWorkspaceMCPProjection.canonicalToolName(
            fromObservedToolName: toolName,
            runtime: manifest.providerID
        ) {
            let permission = DockerWorkspaceMCPProjection.providerToolPermission(for: canonicalWorkspaceTool)
            return manifest.providerRender.runtimeSupportTools.first { descriptor in
                Self.normalizedToolName(descriptor.name) == Self.normalizedToolName(permission)
            }
        }
        if let canonicalHostTool = HostControlPlaneMCPProjection.canonicalToolName(
            fromObservedToolName: toolName,
            runtime: manifest.providerID
        ) {
            let permission = HostControlPlaneMCPProjection.providerToolPermission(for: canonicalHostTool)
            return manifest.providerRender.runtimeSupportTools.first { descriptor in
                Self.normalizedToolName(descriptor.name) == Self.normalizedToolName(permission)
            }
        }
        return manifest.providerRender.runtimeSupportTools.first { descriptor in
            Self.normalizedToolName(descriptor.name) == normalized
                || descriptor.providerNativePermission.map(Self.normalizedToolName) == normalized
        }
    }

    private func validateRuntimeSupportTool(
        _ descriptor: ProviderRuntimeSupportToolDescriptor,
        observed: PolicyObservedEvent,
        toolName: String
    ) -> AgentRuntimePolicyViolation? {
        let allowedKeys = Set(descriptor.allowedInputKeys)
        if let field = disallowedRuntimeSupportActionField(observed, allowedKeys: allowedKeys) {
            return AgentRuntimePolicyViolation(
                reason: "The provider support tool carried action-like input outside its safe runtime schema: \(field)",
                toolName: toolName,
                detail: observed.summary,
                violationCategory: "runtime_support_tool_action_field"
            )
        }

        let observedKeys = Set(observed.inputKeys)
        let deniedInputKeys = Set(descriptor.deniedInputKeys)
        let actionLikeKeys = observedKeys.intersection(deniedInputKeys).sorted()
        if !actionLikeKeys.isEmpty {
            return AgentRuntimePolicyViolation(
                reason: "The provider support tool carried action-like input keys outside its safe runtime schema: \(actionLikeKeys.joined(separator: ", "))",
                toolName: toolName,
                detail: observed.summary,
                violationCategory: "runtime_support_tool_action_key"
            )
        }

        let unsupportedKeys = observedKeys.subtracting(allowedKeys).sorted()
        if !unsupportedKeys.isEmpty {
            return AgentRuntimePolicyViolation(
                reason: "The provider support tool used unsupported input keys: \(unsupportedKeys.joined(separator: ", "))",
                toolName: toolName,
                detail: observed.summary,
                violationCategory: "runtime_support_tool_input_schema"
            )
        }

        if let summary = observed.summary,
           summary.count > descriptor.maxSummaryLength {
            return AgentRuntimePolicyViolation(
                reason: "The provider support tool input exceeded its safe summary limit",
                toolName: toolName,
                detail: String(summary.prefix(240)),
                violationCategory: "runtime_support_tool_summary_length"
            )
        }

        return nil
    }

    private func disallowedRuntimeSupportActionField(
        _ observed: PolicyObservedEvent,
        allowedKeys: Set<String>
    ) -> String? {
        if observed.command != nil,
           !allowedKeys.contains("command"),
           !allowedKeys.contains("cmd") {
            return "command"
        }
        if observed.path != nil,
           !allowedKeys.contains("path"),
           !allowedKeys.contains("file_path"),
           !allowedKeys.contains("filepath") {
            return "path"
        }
        if observed.url != nil,
           !allowedKeys.contains("url"),
           !allowedKeys.contains("uri") {
            return "url"
        }
        return nil
    }

    private func validateDeniedShellCommand(command: String?, toolName: String) -> AgentRuntimePolicyViolation? {
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if manifest.providerRender.deniedShellPatterns.contains("*") {
            return AgentRuntimePolicyViolation(
                reason: "Shell execution is denied by the effective ASTRA policy",
                toolName: toolName,
                detail: trimmedCommand.isEmpty ? nil : trimmedCommand
            )
        }

        guard !trimmedCommand.isEmpty,
              matchesAnyShellPattern(trimmedCommand, patterns: manifest.providerRender.deniedShellPatterns) else {
            return nil
        }
        return AgentRuntimePolicyViolation(
            reason: "The shell command matches a denied command pattern",
            toolName: toolName,
            detail: trimmedCommand
        )
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
           !shellCommandAllowedByPatterns(trimmedCommand, patterns: allowedShellPatterns),
           !toolPatternAllowsShellCommand(trimmedCommand) {
            if matchesAnyShellPattern(trimmedCommand, patterns: manifest.providerRender.askFirstShellPatterns) {
                let request = PermissionRequest.shell(command: trimmedCommand, toolName: toolName)
                return AgentRuntimePolicyViolation(
                    reason: "The shell command requires user approval by the effective ASTRA policy",
                    toolName: toolName,
                    detail: trimmedCommand,
                    requiresApproval: true,
                    permissionRequest: request,
                    approvalGrants: PermissionBroker.approvalGrants(for: request)
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
        guard isMutationTool(toolName) else {
            return isPathReadable(path) ? nil : outOfBoundaryReadViolation(path: path, toolName: toolName)
        }
        guard isPathWritable(path) else {
            return AgentRuntimePolicyViolation(
                reason: "The file path is outside the workspace paths allowed for this run",
                toolName: toolName,
                detail: path
            )
        }
        return nil
    }

    /// A read outside the run boundary is a question, not a capital offence.
    ///
    /// Two facts make termination the wrong answer here. First, nothing at the
    /// provider tier ever told the agent a read boundary existed: ASTRA renders
    /// read permission unqualified (`Read(*)`), because no provider CLI scopes
    /// reads the way it scopes writes. Enforcing a boundary the agent was never
    /// given is a rule it cannot follow. Second, by the time this violation is
    /// parsed out of the provider's stream the read has already completed —
    /// killing the process prevents nothing and throws away the whole session.
    ///
    /// So make it answerable instead: with a live control channel the provider
    /// is told "no" as a tool result and keeps working; without one the user
    /// gets an approval card whose `.sandboxPath` grant widens
    /// `additionalReadOnlyPaths` on the retry. Writes keep the terminal
    /// violation — those are integrity events, and the write boundary *is*
    /// declared to the provider.
    private func outOfBoundaryReadViolation(path: String, toolName: String) -> AgentRuntimePolicyViolation {
        let request = PermissionRequest.sandboxPath(path: path, access: "read", toolName: toolName)
        return AgentRuntimePolicyViolation(
            reason: "The file path is outside the read paths allowed for this run",
            toolName: toolName,
            detail: path,
            violationCategory: "out_of_boundary_read",
            requiresApproval: true,
            permissionRequest: request,
            approvalGrants: PermissionBroker.approvalGrants(for: request)
        )
    }

    private func matchesTaskOutputFileMutation(_ observed: PolicyObservedEvent, toolName: String) -> Bool {
        guard isMutationTool(toolName),
              observed.command == nil else {
            return false
        }

        if isPatchMutationTool(toolName) {
            let paths = patchMutationPaths(from: observed)
            guard !paths.isEmpty,
                  paths.allSatisfy(isWritableTaskOutputFilePath) else {
                return false
            }
            return toolMatches(toolName, command: nil, candidates: manifest.providerRender.askFirstTools)
        }

        guard let path = observed.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              isWritableTaskOutputFilePath(path) else {
            return false
        }
        return toolMatches(toolName, command: nil, candidates: manifest.providerRender.askFirstTools)
    }

    private func matchesApprovedFileMutationGrant(_ observed: PolicyObservedEvent, toolName: String) -> Bool {
        guard isMutationTool(toolName),
              observed.command == nil else {
            return false
        }

        let paths = mutationPaths(from: observed, toolName: toolName)
        guard !paths.isEmpty else { return false }
        let approvedPaths = manifest.approvalGrants.compactMap { grant -> String? in
            guard case .filePath(let path, let access) = grant,
                  Self.isWriteAccess(access) else {
                return nil
            }
            return standardizedRunPath(path)
        }
        guard !approvedPaths.isEmpty else { return false }
        return paths
            .map(standardizedRunPath)
            .allSatisfy { candidate in
                approvedPaths.contains(candidate)
            }
    }

    private func validateTaskOutputMutationOwnership(
        _ observed: PolicyObservedEvent,
        toolName: String
    ) -> AgentRuntimePolicyViolation? {
        let paths = mutationPaths(from: observed, toolName: toolName)
        guard let internalPath = paths.first(where: { path in
            guard isPathInTaskOutput(path) else { return false }
            return !isWritableTaskOutputFilePath(path)
        }) else {
            return nil
        }
        return AgentRuntimePolicyViolation(
            reason: "The file path is ASTRA-owned task runtime state and cannot be created or modified by the provider",
            toolName: toolName,
            detail: internalPath,
            violationCategory: "runtime_state_path_mutation"
        )
    }

    private func validateReadOnlyInputMutation(
        _ observed: PolicyObservedEvent,
        toolName: String
    ) -> AgentRuntimePolicyViolation? {
        let paths = mutationPaths(from: observed, toolName: toolName)
        guard let readOnlyPath = paths.first(where: isReadOnlyInputPath) else {
            return nil
        }
        return AgentRuntimePolicyViolation(
            reason: "The file path is a read-only task input and cannot be modified by the provider",
            toolName: toolName,
            detail: readOnlyPath,
            violationCategory: "read_only_input_mutation"
        )
    }

    private func mutationPaths(from observed: PolicyObservedEvent, toolName: String) -> [String] {
        if isPatchMutationTool(toolName) {
            return patchMutationPaths(from: observed)
        }
        return [observed.path]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func validatePatchMutationPaths(
        _ observed: PolicyObservedEvent,
        toolName: String
    ) -> AgentRuntimePolicyViolation? {
        let paths = patchMutationPaths(from: observed)
        guard !paths.isEmpty else {
            return AgentRuntimePolicyViolation(
                reason: "ASTRA could not validate the patch file paths for a mutating tool",
                toolName: toolName,
                detail: observed.summary
            )
        }

        if let outsidePath = paths.first(where: { !isPathWritable($0) }) {
            return AgentRuntimePolicyViolation(
                reason: "The patch file path is outside the workspace paths allowed for this run",
                toolName: toolName,
                detail: outsidePath
            )
        }

        return nil
    }

    private func patchMutationPaths(from observed: PolicyObservedEvent) -> [String] {
        let candidates = [
            observed.summary,
            observed.path
        ].compactMap { $0 }

        var paths: [String] = []
        for candidate in candidates {
            paths.append(contentsOf: PolicyObservedEvent.patchFilePaths(in: candidate))
        }

        if paths.isEmpty,
           let path = observed.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            paths.append(path)
        }

        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
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

    private func isPathReadable(_ rawPath: String) -> Bool {
        boundary.isReadable(rawPath)
    }

    private func isPathWritable(_ rawPath: String) -> Bool {
        boundary.isWritable(rawPath)
    }

    private func isReadOnlyInputPath(_ rawPath: String) -> Bool {
        boundary.isReadOnlyInput(rawPath)
    }

    private func isPathInTaskOutput(_ rawPath: String) -> Bool {
        boundary.isInTaskOutput(rawPath)
    }

    private func isWritableTaskOutputFilePath(_ rawPath: String) -> Bool {
        guard let relativePath = boundary.taskOutputRelativePath(rawPath),
              !relativePath.isEmpty else {
            return false
        }
        return TaskGeneratedFiles.shouldDisplayTaskFolderFile(relativePath: relativePath)
    }

    private func standardizedRunPath(_ rawPath: String) -> String {
        boundary.standardizedRunPath(rawPath)
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

    private enum ShellPatternMatchMode {
        case anySegment
        case allActionableSegments
    }

    private func toolMatches(
        _ tool: String,
        command: String?,
        candidates: [String],
        shellMatchMode: ShellPatternMatchMode = .anySegment
    ) -> Bool {
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
                    if let command, shellCommandMatchesPattern(command, pattern: pattern, mode: shellMatchMode) {
                        return true
                    }
                }
                if normalizedCandidateTool == "bash",
                   let command,
                   shellCommandMatchesPattern(command, pattern: pattern, mode: shellMatchMode) {
                    return true
                }
                continue
            }

            if providerToolMatches(candidate: trimmed, observedTool: tool) {
                return true
            }
            if isShellTool(tool),
               lower.hasPrefix("shell("),
               let command,
               matchesShellPermission(command, permission: lower, mode: shellMatchMode) {
                return true
            }
        }

        return false
    }

    private func toolPatternAllowsShellCommand(_ command: String) -> Bool {
        effectiveAllowedToolCandidates.contains { candidate in
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
            return shellCommandAllowedByPattern(command, pattern: pattern)
        }
    }

    /// The durable typed grants in the run manifest are the authority for a
    /// one-run approval. Some runtimes (including Codex CLI) cannot project
    /// fine-grained tool grants into provider-native flags, so the ASTRA guard
    /// must apply the adapter-normalized grant itself instead of relying on the
    /// provider render to echo it back through `allowedTools`.
    private var effectiveAllowedToolCandidates: [String] {
        let approved = PermissionBroker.providerRuntimeGrantStrings(
            for: manifest.approvalGrants,
            runtime: manifest.providerID
        )
        return Array(Set(manifest.providerRender.allowedTools + approved)).sorted()
    }

    private func matchesShellPermission(_ command: String, permission: String, mode: ShellPatternMatchMode) -> Bool {
        guard let openParen = permission.firstIndex(of: "("),
              permission.hasSuffix(")") else {
            return false
        }
        let patternStart = permission.index(after: openParen)
        let pattern = String(permission[patternStart..<permission.index(before: permission.endIndex)])
        return shellCommandMatchesPattern(command, pattern: pattern, mode: mode)
    }

    private func providerToolMatches(candidate: String, observedTool: String) -> Bool {
        let candidateTool = Self.normalizedToolName(candidate)
        let observedTool = Self.normalizedToolName(observedTool)
        if candidateTool == observedTool {
            return true
        }
        if manifest.providerID == .copilotCLI {
            if candidateTool == "read",
               ["read", "view", "grep", "glob", "ls"].contains(observedTool) {
                return true
            }
            if candidateTool == "write",
               ["write", "create", "edit", "multiedit"].contains(observedTool) {
                return true
            }
        }
        return false
    }

    private func matchesAnyShellPattern(_ command: String, patterns: [String]) -> Bool {
        patterns.contains { matchesShellPattern(command, pattern: $0) }
    }

    private func shellCommandMatchesPattern(_ command: String, pattern: String, mode: ShellPatternMatchMode) -> Bool {
        switch mode {
        case .anySegment:
            return matchesShellPattern(command, pattern: pattern)
        case .allActionableSegments:
            return shellCommandAllowedByPattern(command, pattern: pattern)
        }
    }

    private func shellCommandAllowedByPatterns(_ command: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        if patterns.contains("*") { return true }
        let segments = Self.actionableShellSegments(command)
        let normalizedCommand = Self.normalizedShellText(command)
        if patterns.contains(where: {
            canMatchFullShellCommand(pattern: $0, segmentCount: segments.count)
                && matchesFullShellCommand(normalizedCommand, pattern: $0)
        }) {
            return true
        }
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            Self.isBenignShellSetupSegment(segment)
                || patterns.contains { matchesShellSegment(segment, pattern: $0) }
        }
    }

    private func shellCommandAllowedByPattern(_ command: String, pattern: String) -> Bool {
        let segments = Self.actionableShellSegments(command)
        let normalizedCommand = Self.normalizedShellText(command)
        if canMatchFullShellCommand(pattern: pattern, segmentCount: segments.count),
           matchesFullShellCommand(normalizedCommand, pattern: pattern) {
            return true
        }
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            Self.isBenignShellSetupSegment(segment)
                || matchesShellSegment(segment, pattern: pattern)
        }
    }

    private func matchesShellPattern(_ command: String, pattern: String) -> Bool {
        let normalizedCommand = Self.normalizedShellText(command)
        if matchesFullShellCommand(normalizedCommand, pattern: pattern) {
            return true
        }
        let normalizedPattern = normalizedShellPattern(pattern)
        if let barePattern = Self.bareShellPatternRoot(normalizedPattern),
           normalizedCommand == barePattern {
            return true
        }
        return Self.shellCommandSegmentVariants(command).contains { candidate in
            matchesShellSegment(candidate, pattern: pattern)
        }
    }

    private func matchesFullShellCommand(_ normalizedCommand: String, pattern: String) -> Bool {
        let normalizedPattern = normalizedShellPattern(pattern)
        return Self.wildcardMatch(normalizedCommand, pattern: normalizedPattern)
    }

    private func canMatchFullShellCommand(pattern: String, segmentCount: Int) -> Bool {
        guard segmentCount > 1 else { return true }
        let normalizedPattern = normalizedShellPattern(pattern)
        return normalizedPattern.contains("|")
            || normalizedPattern.contains(";")
            || normalizedPattern.contains("&&")
            || normalizedPattern.contains("||")
            || normalizedPattern.contains("$(")
            || normalizedPattern.contains("`")
    }

    private func matchesShellSegment(_ segment: String, pattern: String) -> Bool {
        let normalizedSegment = Self.normalizedShellText(segment)
        let normalizedPattern = normalizedShellPattern(pattern)
        return Self.wildcardMatch(normalizedSegment, pattern: normalizedPattern)
            || Self.bareShellPatternRoot(normalizedPattern) == normalizedSegment
            || Self.wildcardMatch(Self.normalizedShellText(Self.segmentWithExecutableBasename(normalizedSegment)), pattern: normalizedPattern)
            || shellPathScopeMatches(normalizedSegment: normalizedSegment, normalizedPattern: normalizedPattern)
    }

    private func shellPathScopeMatches(normalizedSegment: String, normalizedPattern: String) -> Bool {
        let patternTokens = normalizedPattern.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let segmentTokens = normalizedSegment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard patternTokens.count >= 2,
              let patternRoot = patternTokens.first,
              let segmentRoot = segmentTokens.first,
              shellRootsMatch(observedRoot: segmentRoot, allowedRoot: patternRoot) else {
            return false
        }

        let segmentText = Self.normalizedShellText(Self.shellPathComparableText(normalizedSegment))
        let segmentBasenameText = Self.normalizedShellText(Self.shellPathComparableText(Self.segmentWithExecutableBasename(normalizedSegment)))
        for token in patternTokens.dropFirst() {
            guard token != "*",
                  token.contains("/"),
                  token.count >= 8,
                  !token.contains(".."),
                  token.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r;&|`$<>")) == nil else {
                continue
            }
            let pathToken = Self.normalizedShellText(Self.shellPathComparableText(token))
            if Self.shellText(segmentText, containsPathScopeToken: pathToken)
                || Self.shellText(segmentBasenameText, containsPathScopeToken: pathToken) {
                return true
            }
        }
        return false
    }

    private func shellRootsMatch(observedRoot: String, allowedRoot: String) -> Bool {
        let normalizedAllowed = Self.normalizedShellText(Self.segmentWithExecutableBasename(allowedRoot))
        let normalizedObserved = Self.normalizedShellText(Self.segmentWithExecutableBasename(observedRoot))
        return normalizedObserved == normalizedAllowed
    }

    private func normalizedShellPattern(_ pattern: String) -> String {
        Self.normalizedShellText(pattern.replacingOccurrences(of: ":", with: " "))
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

    private func isPatchMutationTool(_ tool: String) -> Bool {
        tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apply_patch"
    }

    private func isFileTool(_ tool: String) -> Bool {
        ["read", "grep", "glob", "ls", "write", "edit", "multiedit"].contains(Self.normalizedToolName(tool))
    }

    private func isNetworkTool(_ tool: String) -> Bool {
        ["webfetch", "websearch"].contains(Self.normalizedToolName(tool))
    }

    private static func normalizedToolName(_ tool: String) -> String {
        ProviderToolSemantics.normalizedName(tool)
    }

    private static func isWriteAccess(_ access: String) -> Bool {
        let normalized = access.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "write" || normalized == "rw" || normalized == "readwrite" || normalized == "read-write"
    }

    private static func shellCommandRoot(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = stripShellComment(from: command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    private static func shellApprovalCommandRoot(_ command: String?) -> String? {
        guard let command else { return nil }
        let segments = actionableShellSegments(command)
        if let substantive = segments.first(where: { !isBenignShellSetupSegment($0) }),
           let root = shellCommandRoot(substantive) {
            return root
        }
        return nil
    }

    private static func normalizedShellText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func shellPathComparableText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\ "#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\/"#, with: "/", options: .regularExpression)
    }

    private static func shellText(_ text: String, containsPathScopeToken token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.hasPrefix("/") {
            return text.contains(token)
        }
        return text.contains(" \(token)")
            || text.contains("/\(token)")
            || text.contains("'\(token)")
            || text.contains("\"\(token)")
    }

    private static func shellCommandSegmentVariants(_ command: String) -> [String] {
        let semanticCommand = ProviderToolSemantics.semanticShellCommand(command)
        let separatorsNormalized = shellSegmentSeparatorsNormalized(semanticCommand)
        let rawSegments = separatorsNormalized
            .split(whereSeparator: { $0.isNewline || $0 == ";" })
            .map(String.init)
        var variants: [String] = []
        for rawSegment in rawSegments {
            let normalized = normalizedShellText(rawSegment)
            appendUnique(normalized, to: &variants)
            let actionable = actionableShellSegment(rawSegment)
            appendUnique(normalizedShellText(actionable), to: &variants)
            appendUnique(normalizedShellText(segmentWithExecutableBasename(actionable)), to: &variants)
        }
        return variants
    }

    private static func actionableShellSegments(_ command: String) -> [String] {
        let semanticCommand = ProviderToolSemantics.semanticShellCommand(command)
        let separatorsNormalized = shellSegmentSeparatorsNormalized(semanticCommand)
        let rawSegments = separatorsNormalized
            .split(whereSeparator: { $0.isNewline || $0 == ";" })
            .map(String.init)
        var segments: [String] = []
        for rawSegment in rawSegments {
            let actionable = actionableShellSegment(rawSegment)
            let normalized = normalizedShellText(actionable)
            appendUnique(normalized, to: &segments)
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
        while let first = tokens.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'({[")).lowercased(),
              shellControlWords.contains(first) {
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

    private static func segmentWithExecutableBasename(_ segment: String) -> String {
        var tokens = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return segment }
        var executable = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'({["))
        executable = executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"')}]"))
        if executable.hasPrefix("/") {
            executable = URL(fileURLWithPath: executable).lastPathComponent
        }
        tokens[0] = executable
        return tokens.joined(separator: " ")
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    private static func bareShellPatternRoot(_ pattern: String) -> String? {
        guard pattern.hasSuffix(" *") else { return nil }
        let root = String(pattern.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    private static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        WildcardPatternMatcher.shared.matches(value, pattern: pattern)
    }

    static func commandHintFromShellPermissionToolName(_ toolName: String) -> String? {
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
