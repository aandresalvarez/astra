import Foundation
import ASTRACore
import ASTRAModels

enum RunActivitySeverity: String, Hashable, Sendable {
    case info
    case warning
    case error
}

struct RunFactPresentation: Identifiable, Hashable, Sendable {
    let title: String
    let value: String
    var isMonospaced = false

    var id: String { "\(title)#\(value)" }
}

struct ToolActivityPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let toolName: String
    let detail: String?
    let detailKind: TaskToolDetailKind
    let count: Int
    let rawPayloads: [String]

    var detailLabel: String? {
        switch detailKind {
        case .command: "Command"
        case .path: "Path"
        case .url: "URL"
        case .summary: "Detail"
        case .none: nil
        }
    }

    var countLabel: String {
        count == 1 ? "1 call" : "\(count) calls"
    }
}

struct RunIssuePresentation: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let severity: RunActivitySeverity
    let rawPayload: String?

    init(notice: TaskRunNotice) {
        id = notice.id
        let payload = notice.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        switch notice.type {
        case "budget.warning":
            title = "Budget warning"
            summary = Self.budgetWarningBody(for: payload)
            severity = .warning
        case "budget.exceeded":
            title = "Budget exceeded"
            summary = "This task exceeded its budget. Resume with a higher budget or retry with a narrower request."
            severity = .error
        case "permission.approval.requested":
            let approval = RuntimePermissionApprovalText(payload: payload)
            title = "Permission requested"
            summary = approval.noticeBody
            severity = .info
        case "error" where Self.looksPolicyBlocked(payload):
            title = "Policy blocked this run"
            summary = "ASTRA stopped this run because the requested action is outside the current policy. Review the policy or retry with broader permissions."
            severity = .error
        case "error":
            title = "Run stopped"
            summary = Self.providerErrorBody(for: payload)
            severity = .error
        default:
            title = "Notice"
            summary = payload
            severity = .info
        }

        rawPayload = payload.isEmpty || payload == summary ? nil : PayloadFormatter.prettyRawPayload(payload)
    }

    static func looksPolicyBlocked(_ payload: String) -> Bool {
        let lower = payload.lowercased()
        return lower.contains("violated the run policy") ||
            lower.contains("provider allow-list") ||
            lower.contains("policy violation") ||
            lower.contains("not in the provider allow-list")
    }

    private static func budgetWarningBody(for payload: String) -> String {
        let lower = payload.lowercased()
        if lower.contains("launch estimate") {
            return "This task may use more budget than expected. ASTRA continued because budget enforcement is set to warning mode."
        }
        if lower.contains("warning mode") || lower.contains("warning only") {
            return "This task has used more budget than expected. ASTRA kept it running because budget enforcement is set to warning mode."
        }
        return "This task may use more budget than expected. ASTRA continued because budget enforcement is set to warning mode."
    }

    /// Human-authored provider messages stay whole up to this length; the old
    /// hard 220-char cut regularly amputated the actionable last line ("Fix
    /// the capability in Manage Capabilities…"), leaving the fix reachable
    /// only through "Show raw output".
    private static let fullErrorBodyLimit = 600

    private static func providerErrorBody(for payload: String) -> String {
        let lower = payload.lowercased()
        if lower.contains("exited with code") || lower.contains("failed before astra received") {
            return "The provider stopped before returning a visible response. Retry the task or open the raw output below."
        }
        if payload.isEmpty {
            return "The provider stopped unexpectedly. Retry the task or open run details for diagnostics."
        }
        if payload.count <= fullErrorBodyLimit {
            return payload
        }
        return String(payload.prefix(220)) + "…"
    }
}

enum TaskRunNoticePresentationRules {
    static func shouldShowInline(_ notice: TaskRunNotice, for run: TaskRunSnapshot) -> Bool {
        guard !run.hasVPNWarning || notice.type != "error" else { return false }
        switch notice.type {
        case "error", "budget.exceeded", "budget.warning":
            return true
        default:
            return false
        }
    }

    /// Error-class banners are the run's single visible explanation (the
    /// details disclosure no longer repeats them), so they render expanded
    /// with no collapse affordance. Warnings stay collapsible strips.
    static func rendersFixedExpanded(_ notice: TaskRunNotice) -> Bool {
        switch notice.type {
        case "error", "budget.exceeded":
            return true
        default:
            return false
        }
    }

    /// The dock's Details popover is the single run inspector: while the dock
    /// is visible, NO finished run renders an in-thread disclosure — the
    /// inspector stacks every run's sections instead, so the rule is
    /// homogeneous across statuses and multi-run threads. The only exception
    /// is a live run, whose inline activity feed must stay in the thread.
    static func detailsLiveInDock(
        runStatus: RunStatus,
        dockVisible: Bool
    ) -> Bool {
        dockVisible && runStatus != .running
    }
}

struct RuntimePermissionDecisionPresentation: Hashable, Sendable {
    let title: String
    let summary: String
    let scope: String
    let check: String
    let commandPreview: String?
    let grantSummary: String?
    let compactAuditSummary: String
    let allowSimilarLabel: String

    init(payload: String) {
        let approval = RuntimePermissionApprovalText(payload: payload)
        title = approval.decisionTitle
        summary = approval.decisionBody
        scope = "Scope: one time for this run."
        check = approval.checkSummary
        commandPreview = approval.actionPreview
        grantSummary = approval.approvalGrant
        compactAuditSummary = approval.compactSummary
        allowSimilarLabel = approval.allowSimilarLabel
    }
}

struct RuntimePermissionApprovalNoticePresentation: Identifiable, Hashable, Sendable {
    let id: UUID
    let decision: RuntimePermissionDecisionPresentation
    let rawPayload: String?

    init(notice: TaskRunNotice) {
        id = notice.id
        decision = RuntimePermissionDecisionPresentation(payload: notice.payload)
        let raw = notice.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        rawPayload = raw.isEmpty ? nil : PayloadFormatter.prettyRawPayload(raw)
    }
}

struct TechnicalOutputPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let facts: [RunFactPresentation]
    let rawPayload: String
    let severity: RunActivitySeverity
}

struct PolicySummaryPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String?
    let facts: [RunFactPresentation]
    let rawPayload: String?

    init?(
        manifest: RunPermissionManifest?,
        permissionSummaryPayload: String?
    ) {
        guard manifest != nil || permissionSummaryPayload?.isEmpty == false else {
            return nil
        }

        let summaryFacts = permissionSummaryPayload.flatMap(Self.permissionSummaryFacts) ?? []
        let manifestFacts = manifest.map(Self.manifestFacts) ?? []
        let usesBroadMode = manifest?.providerRender.usesBroadProviderPermissions ??
            Self.permissionSummaryBroadMode(permissionSummaryPayload)

        if let manifest {
            id = "policy-\(manifest.runID.uuidString)"
            title = "\(manifest.policyLevel.displayName) policy"
            subtitle = manifest.policyScope.displayName
            badge = usesBroadMode ? "Broad provider mode" : nil
        } else {
            id = "policy-summary"
            title = "Permission summary"
            subtitle = summaryFacts.first(where: { $0.title == "Status" })?.value ?? "Run policy"
            badge = usesBroadMode ? "Broad provider mode" : nil
        }

        facts = Self.uniqueFacts(summaryFacts + manifestFacts)
        rawPayload = permissionSummaryPayload.flatMap(PayloadFormatter.prettyRawPayload)
    }

    static func permissionSummaryFacts(from payload: String) -> [RunFactPresentation] {
        guard let object = PayloadFormatter.jsonObject(from: payload) as? [String: Any] else {
            return []
        }

        var facts: [RunFactPresentation] = []
        appendStringFact("Status", key: "status", object: object, facts: &facts)
        appendStringFact("Stop reason", key: "stopReason", object: object, facts: &facts)
        appendIntFact("Tools used", key: "toolUseCount", object: object, facts: &facts)
        appendIntFact("Permission denials", key: "deniedCount", object: object, facts: &facts)
        appendIntFact("Files changed", key: "fileChangeCount", object: object, facts: &facts)
        appendBoolFact("Broad provider mode", key: "usedBroadProviderPermissions", object: object, facts: &facts)
        appendBoolFact("Exceeded initial policy", key: "exceededInitialPermissionLevel", object: object, facts: &facts)
        appendListFact("Observed tools", key: "toolsUsed", object: object, facts: &facts, limit: 8)
        appendListFact("Commands", key: "commandsRun", object: object, facts: &facts, limit: 4, isMonospaced: true)
        appendListFact("External domains", key: "externalDomains", object: object, facts: &facts, limit: 6)
        appendListFact("Env keys", key: "environmentKeyNames", object: object, facts: &facts, limit: 8, isMonospaced: true)
        appendListFact("Approvals", key: "approvalsGranted", object: object, facts: &facts, limit: 4)
        return facts
    }

    private static func permissionSummaryBroadMode(_ payload: String?) -> Bool {
        guard let payload,
              let object = PayloadFormatter.jsonObject(from: payload) as? [String: Any] else {
            return false
        }
        return object["usedBroadProviderPermissions"] as? Bool ?? false
    }

    private static func manifestFacts(_ manifest: RunPermissionManifest) -> [RunFactPresentation] {
        var facts: [RunFactPresentation] = [
            .init(title: "Provider", value: "\(manifest.providerID.displayName) - \(manifest.model)"),
            .init(title: "Provider version", value: manifest.providerVersion ?? "Unknown"),
            .init(title: "Enforcement", value: manifest.providerRender.enforcementTiers.map(\.displayName).joined(separator: ", ")),
            .init(title: "Config source", value: manifest.providerRender.configOwnership.displayName),
            .init(title: "Allowed tools", value: compactList(manifest.providerRender.allowedTools, empty: "None")),
            .init(title: "Denied tools", value: compactList(manifest.providerRender.deniedTools, empty: "None")),
            .init(title: "Allowed shell", value: compactList(manifest.providerRender.allowedShellPatterns, empty: "None"), isMonospaced: true),
            .init(title: "Denied shell", value: compactList(manifest.providerRender.deniedShellPatterns, empty: "None"), isMonospaced: true),
            .init(title: "Network", value: manifest.providerRender.allowedURLPatterns.isEmpty ? "Ask or connector scoped" : compactList(manifest.providerRender.allowedURLPatterns), isMonospaced: true),
            .init(title: "Paths", value: compactList([manifest.workspacePath] + manifest.additionalPaths, empty: "None"), isMonospaced: true),
            .init(title: "Environment keys", value: compactList(manifest.environmentKeyNames, empty: "None"), isMonospaced: true),
            .init(title: "Credential labels", value: compactList(manifest.credentialLabels, empty: "None")),
            .init(title: "MCP servers", value: mcpServersFactValue(manifest)),
            .init(title: "Approvals", value: compactList(manifest.approvalsGranted, empty: "None"))
        ]

        if !manifest.providerRender.generatedConfigPreview.isEmpty {
            facts.append(.init(title: "Generated config", value: manifest.providerRender.generatedConfigPreview, isMonospaced: true))
        }
        if !manifest.providerRender.diagnostics.isEmpty {
            let diagnostics = manifest.providerRender.diagnostics
                .map { "\($0.severity.rawValue): \($0.title)" }
                .joined(separator: "; ")
            facts.append(.init(title: "Diagnostics", value: diagnostics))
        }
        return facts
    }

    static func mcpServersFactValue(_ manifest: RunPermissionManifest) -> String {
        guard !manifest.mcpServers.isEmpty else { return "None" }
        guard AgentRuntimeAdapterRegistry.descriptor(for: manifest.providerID).supportsMCPServers else {
            // Declared servers must never read as active on a runtime that
            // doesn't materialize them.
            let count = manifest.mcpServers.count
            return "\(count) skipped — \(manifest.providerID.displayName) doesn't support MCP servers"
        }
        return compactList(mcpServerSummaries(manifest.mcpServers), empty: "None")
    }

    private static func mcpServerSummaries(_ servers: [RunPermissionManifest.MCPServer]) -> [String] {
        servers.map { server in
            let toolPolicy = server.allowedTools.isEmpty
                ? "tools:any"
                : "tools:\(server.allowedTools.count)"
            return "\(server.packageID)/\(server.id) \(server.transport) \(toolPolicy)"
        }
    }

    private static func uniqueFacts(_ facts: [RunFactPresentation]) -> [RunFactPresentation] {
        var seen = Set<String>()
        var result: [RunFactPresentation] = []
        for fact in facts where !fact.value.isEmpty {
            let key = fact.id
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(fact)
        }
        return result
    }
}

struct RunActivityPresentation: Hashable, Sendable {
    let issues: [RunIssuePresentation]
    let approvals: [RuntimePermissionApprovalNoticePresentation]
    let progressMessages: [TaskRunProgressMessage]
    let tools: [ToolActivityPresentation]
    let files: [StoredFileChange]
    let policy: PolicySummaryPresentation?
    let technicalOutputs: [TechnicalOutputPresentation]
    let stats: [RunFactPresentation]
    let prefersExpandedDetails: Bool

    init(
        run: TaskRunSnapshot,
        activity: TaskRunActivity,
        notices: [TaskRunNotice],
        suppressedNoticeIDs: Set<UUID> = [],
        progressMessages: [TaskRunProgressMessage] = []
    ) {
        var issueRows: [RunIssuePresentation] = []
        var approvalRows: [RuntimePermissionApprovalNoticePresentation] = []
        var technicalRows: [TechnicalOutputPresentation] = []
        let permissionSummaryPayload = notices.last(where: { $0.type == "astra.permission_summary" })?.payload

        for notice in notices where notice.type != "astra.permission_summary" {
            if notice.type == "permission.approval.requested" {
                approvalRows.append(RuntimePermissionApprovalNoticePresentation(notice: notice))
                continue
            }

            // A suppressed notice is already rendered as an inline banner in
            // the thread (title, summary, AND raw payload). Re-emitting it
            // here as a technical row painted the same failure twice on one
            // screen; the disclosure carries only what the banner doesn't.
            guard !suppressedNoticeIDs.contains(notice.id) else { continue }
            issueRows.append(RunIssuePresentation(notice: notice))
        }

        technicalRows.append(contentsOf: activity.toolResults.map(Self.technicalOutput))

        issues = issueRows
        approvals = approvalRows
        self.progressMessages = progressMessages
        tools = Self.groupToolCalls(activity.toolCalls)
        files = activity.fileChanges
        policy = PolicySummaryPresentation(
            manifest: activity.permissionManifest,
            permissionSummaryPayload: permissionSummaryPayload
        )
        technicalOutputs = technicalRows
        stats = Self.statsFacts(for: run)
        prefersExpandedDetails = Self.prefersExpandedDetails(
            run: run,
            issues: issueRows,
            technicalOutputs: technicalRows,
            hasInlineNotices: !suppressedNoticeIDs.isEmpty
        )
    }

    var hasVisibleDetails: Bool {
        !issues.isEmpty || !approvals.isEmpty || !progressMessages.isEmpty || !tools.isEmpty || !files.isEmpty || policy != nil || !technicalOutputs.isEmpty || !stats.isEmpty
    }

    private static func prefersExpandedDetails(
        run: TaskRunSnapshot,
        issues: [RunIssuePresentation],
        technicalOutputs: [TechnicalOutputPresentation],
        hasInlineNotices: Bool
    ) -> Bool {
        // When an inline banner already explains the failure, auto-opening
        // the disclosure too stacks a second block under the first; the
        // status-driven expansion is only for runs with no banner to speak
        // for them.
        if run.status.prefersExpandedRunActivityDetails, !hasInlineNotices {
            return true
        }
        if issues.contains(where: { $0.severity == .error }) {
            return true
        }
        if technicalOutputs.contains(where: { $0.severity == .error }) {
            return true
        }
        return false
    }

    private static func groupToolCalls(_ calls: [TaskToolCall]) -> [ToolActivityPresentation] {
        var order: [String] = []
        var grouped: [String: (call: TaskToolCall, count: Int, rawPayloads: [String])] = [:]

        for call in calls {
            let key = [
                call.toolName,
                call.detailKind.rawValue,
                call.detail ?? ""
            ].joined(separator: "#")
            if var existing = grouped[key] {
                existing.count += 1
                existing.rawPayloads.append(call.rawPayload)
                grouped[key] = existing
            } else {
                order.append(key)
                grouped[key] = (call, 1, [call.rawPayload])
            }
        }

        return order.compactMap { key in
            guard let group = grouped[key] else { return nil }
            return ToolActivityPresentation(
                id: key,
                toolName: group.call.toolName,
                detail: group.call.detail,
                detailKind: group.call.detailKind,
                count: group.count,
                rawPayloads: group.rawPayloads
            )
        }
    }

    private static func technicalOutput(_ result: TaskToolResult) -> TechnicalOutputPresentation {
        let summary = PayloadFormatter.summary(for: result.payload)
        return TechnicalOutputPresentation(
            id: "tool-result-\(result.id.uuidString)",
            title: "Tool result",
            summary: summary.summary,
            facts: summary.facts,
            rawPayload: summary.rawPayload,
            severity: .info
        )
    }

    private static func statsFacts(for run: TaskRunSnapshot) -> [RunFactPresentation] {
        var facts: [RunFactPresentation] = []
        if run.tokensUsed > 0 {
            facts.append(.init(title: "Tokens", value: Formatters.formatTokens(run.tokensUsed)))
        }
        if let completed = run.completedAt {
            let seconds = max(0, Int(completed.timeIntervalSince(run.startedAt)))
            facts.append(.init(title: "Duration", value: seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"))
        }
        if run.costUSD > 0 {
            facts.append(.init(title: "Cost", value: String(format: "$%.4f", run.costUSD)))
        }
        if let exitCode = run.exitCode {
            facts.append(.init(title: "Exit code", value: String(exitCode)))
        }
        if !run.stopReason.isEmpty {
            facts.append(.init(title: "Stop reason", value: run.stopReason))
        }
        return facts
    }

    static let empty = RunActivityPresentation(
        issues: [],
        approvals: [],
        progressMessages: [],
        tools: [],
        files: [],
        policy: nil,
        technicalOutputs: [],
        stats: [],
        prefersExpandedDetails: false
    )

    private init(
        issues: [RunIssuePresentation],
        approvals: [RuntimePermissionApprovalNoticePresentation],
        progressMessages: [TaskRunProgressMessage],
        tools: [ToolActivityPresentation],
        files: [StoredFileChange],
        policy: PolicySummaryPresentation?,
        technicalOutputs: [TechnicalOutputPresentation],
        stats: [RunFactPresentation],
        prefersExpandedDetails: Bool
    ) {
        self.issues = issues
        self.approvals = approvals
        self.progressMessages = progressMessages
        self.tools = tools
        self.files = files
        self.policy = policy
        self.technicalOutputs = technicalOutputs
        self.stats = stats
        self.prefersExpandedDetails = prefersExpandedDetails
    }
}

struct RunActivityDisclosureState: Hashable, Sendable {
    private var manuallyExpandedRunIDs: Set<UUID> = []
    private var manuallyCollapsedRunIDs: Set<UUID> = []

    func isExpanded(
        runID: UUID,
        presentation: RunActivityPresentation
    ) -> Bool {
        if manuallyCollapsedRunIDs.contains(runID) {
            return false
        }
        if manuallyExpandedRunIDs.contains(runID) {
            return true
        }
        return presentation.prefersExpandedDetails
    }

    mutating func toggle(
        runID: UUID,
        presentation: RunActivityPresentation
    ) {
        if isExpanded(runID: runID, presentation: presentation) {
            manuallyExpandedRunIDs.remove(runID)
            manuallyCollapsedRunIDs.insert(runID)
        } else {
            manuallyCollapsedRunIDs.remove(runID)
            manuallyExpandedRunIDs.insert(runID)
        }
    }
}

private extension RunStatus {
    var prefersExpandedRunActivityDetails: Bool {
        switch self {
        case .failed, .timeout, .budgetExceeded:
            true
        case .running, .completed, .cancelled:
            false
        }
    }
}

enum PayloadFormatter {
    struct Summary: Hashable, Sendable {
        let summary: String
        let facts: [RunFactPresentation]
        let rawPayload: String
    }

    static func summary(for payload: String) -> Summary {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Summary(summary: "No output.", facts: [], rawPayload: "")
        }
        guard let object = jsonObject(from: trimmed) else {
            return Summary(
                summary: compactText(trimmed),
                facts: [],
                rawPayload: trimmed
            )
        }

        let facts = jsonFacts(from: object)
        return Summary(
            summary: jsonSummary(from: object) ?? compactText(trimmed),
            facts: facts,
            rawPayload: prettyRawPayload(trimmed)
        )
    }

    static func prettyRawPayload(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = jsonObject(from: trimmed),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8) else {
            return trimmed
        }
        return pretty
    }

    static func jsonObject(from payload: String) -> Any? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func embeddedJSONObject(from payload: String) -> Any? {
        for index in payload.indices where payload[index] == "{" || payload[index] == "[" {
            let suffix = String(payload[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = jsonObject(from: suffix) {
                return object
            }

            let closingCharacter: Character = payload[index] == "[" ? "]" : "}"
            guard let endIndex = suffix.lastIndex(of: closingCharacter) else { continue }
            let candidate = String(suffix[...endIndex])
            if let object = jsonObject(from: candidate) {
                return object
            }
        }

        return nil
    }

    private static func jsonSummary(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] {
                return "\(array.count) item\(array.count == 1 ? "" : "s")"
            }
            return nil
        }

        if let error = compactString(dictionary["error"]) {
            return error
        }
        if let hint = compactString(dictionary["hint"]) {
            return hint
        }
        if let title = compactString(dictionary["title"]) {
            if dictionary["safeEditUnavailable"] as? Bool == true {
                return "\(title): safe edit unavailable"
            }
            return title
        }
        if dictionary["safeEditUnavailable"] as? Bool == true {
            return "Safe edit unavailable."
        }
        if let ok = dictionary["ok"] as? Bool {
            return ok ? "Completed successfully." : "Did not complete successfully."
        }
        if let status = compactString(dictionary["status"]) {
            return "Status: \(status)"
        }
        return nil
    }

    private static func jsonFacts(from object: Any) -> [RunFactPresentation] {
        guard let dictionary = object as? [String: Any] else { return [] }
        let keys = [
            "error", "hint", "title", "url", "ok", "safeEditUnavailable",
            "status", "stopReason", "toolUseCount", "deniedCount", "fileChangeCount",
            "commandsRun", "externalDomains", "environmentKeyNames"
        ]
        return keys.compactMap { key in
            guard let value = dictionary[key],
                  let string = displayString(value),
                  !string.isEmpty else {
                return nil
            }
            return RunFactPresentation(
                title: factTitle(for: key),
                value: string,
                isMonospaced: key == "commandsRun" || key == "environmentKeyNames"
            )
        }
    }

    private static func displayString(_ value: Any) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? Bool {
            return value ? "Yes" : "No"
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Double {
            return String(value)
        }
        if let values = value as? [String] {
            return compactList(values)
        }
        if let values = value as? [Any] {
            return compactList(values.compactMap(displayString))
        }
        return nil
    }

    private static func compactString(_ value: Any?) -> String? {
        guard let value,
              let string = displayString(value) else {
            return nil
        }
        return compactText(string)
    }

    private static func compactText(_ text: String, limit: Int = 240) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return "\(oneLine.prefix(limit))..."
    }

    private static func factTitle(for key: String) -> String {
        switch key {
        case "safeEditUnavailable": "Safe edit unavailable"
        case "stopReason": "Stop reason"
        case "toolUseCount": "Tools used"
        case "deniedCount": "Permission denials"
        case "fileChangeCount": "Files changed"
        case "commandsRun": "Commands"
        case "externalDomains": "External domains"
        case "environmentKeyNames": "Env keys"
        default:
            key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}

struct RuntimePermissionApprovalText: Hashable, Sendable {
    let payload: String
    let toolName: String?
    let observedAction: String?
    let reason: String?
    let detail: String?
    let approvalGrant: String?
    let providerDetailSummary: String?

    init(payload: String) {
        self.payload = PermissionBroker.displayMessage(from: payload).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = self.payload
        toolName = Self.toolName(in: trimmed)
        reason = Self.field(
            named: "Why approval is needed:",
            in: trimmed,
            stoppingBefore: Self.fieldStopMarkers
        )
        detail = Self.field(
            named: "Detail:",
            in: trimmed,
            stoppingBefore: ["Runtime grant:", "Provider detail:"]
        )
        approvalGrant = Self.field(
            named: "Runtime grant:",
            in: trimmed,
            stoppingBefore: ["Provider detail:"]
        )
        let parsedObservedAction = Self.field(
            named: "What ASTRA observed:",
            in: trimmed,
            stoppingBefore: Self.fieldStopMarkers
        )
        observedAction = parsedObservedAction
            ?? Self.observedActionDescription(toolName: toolName, detail: detail)

        if let providerDetail = Self.field(
            named: "Provider detail:",
            in: trimmed,
            stoppingBefore: []
        ) {
            providerDetailSummary = Self.providerApprovalSummary(for: providerDetail)
        } else {
            providerDetailSummary = nil
        }
    }

    var compactSummary: String {
        guard !payload.isEmpty else {
            return "Permission requested"
        }

        let trimmedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var summary = trimmedToolName.isEmpty ? "Provider access" : trimmedToolName
        if let action = actionPreview, !action.isEmpty {
            summary += " · \(action)"
        }
        return Self.compactText(summary, limit: 96)
    }

    var decisionSummary: String {
        guard !payload.isEmpty else {
            return "Review the policy request before continuing this run."
        }
        return Self.compactText("\(decisionBody) \(scopeSentence)", limit: 190)
    }

    var decisionTitle: String {
        switch accessKind {
        case .shell:
            switch shellRoot {
            case "gh":
                if actionDetail?.localizedCaseInsensitiveContains("pr") == true ||
                    actionDetail?.localizedCaseInsensitiveContains("pull request") == true ||
                    actionDetail?.localizedCaseInsensitiveContains("prs") == true {
                    return "GitHub PR command needs permission"
                }
                return "GitHub command needs permission"
            case "bq":
                return "BigQuery command needs permission"
            case "gcloud":
                return "Google Cloud command needs permission"
            case "curl", "wget":
                return "Network request needs permission"
            case "cat", "head", "tail", "less", "more", "ls", "find":
                return "File command needs permission"
            default:
                return "Shell command needs permission"
            }
        case .fileRead:
            return "File read needs permission"
        case .fileWrite:
            return "File change needs permission"
        case .network:
            return "Network access needs permission"
        case .provider:
            let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(name.isEmpty ? "Provider" : name) access needs permission"
        }
    }

    var decisionBody: String {
        let action = actionPreview
        switch accessKind {
        case .shell:
            switch shellRoot {
            case "gh":
                return "ASTRA wants to use your GitHub CLI login for this task."
            case "bq":
                return "ASTRA wants to run a BigQuery command with your local Google Cloud credentials."
            case "gcloud":
                return "ASTRA wants to run a Google Cloud command with your local cloud credentials."
            case "curl", "wget":
                return "ASTRA wants to contact this network destination from your machine."
            default:
                if let action, !action.isEmpty {
                    return "ASTRA wants to run this local command: \(action)."
                }
                return "ASTRA wants to run a local shell command with this task's environment."
            }
        case .fileRead:
            return action.map { "ASTRA wants to read \($0)." } ?? "ASTRA wants to read a local file."
        case .fileWrite:
            return action.map { "ASTRA wants to change \($0)." } ?? "ASTRA wants to change a local file."
        case .network:
            return action.map { "ASTRA wants to access \($0)." } ?? "ASTRA wants to access a network destination."
        case .provider:
            return action.map { "ASTRA wants to use \(accessLabel): \($0)." } ?? "ASTRA wants to use \(accessLabel)."
        }
    }

    var checkSummary: String {
        Self.sentence(decisionGuidance)
    }

    var actionPreview: String? {
        actionDetail.map { Self.compactText($0, limit: 140) }
    }

    var allowSimilarLabel: String {
        switch shellRoot {
        case "gh":
            return "Allow similar GitHub commands"
        case "bq":
            return "Allow similar BigQuery commands"
        case "gcloud":
            return "Allow similar Google Cloud commands"
        case "curl", "wget":
            return "Allow similar network reads"
        default:
            return "Allow similar for this task"
        }
    }

    var noticeBody: String {
        guard !payload.isEmpty else {
            return "Review the policy request to continue this run."
        }

        var parts = ["ASTRA paused before continuing because the current policy requires approval."]
        if let action = actionPreview, !action.isEmpty {
            parts.append("Requested: \(action)")
        }
        parts.append(scopeSentence)
        parts.append("Check: \(decisionGuidance)")
        if let providerDetailSummary, !providerDetailSummary.isEmpty {
            parts.append("Provider detail: \(providerDetailSummary)")
        }
        return parts.joined(separator: "\n\n")
    }

    private var scopeSentence: String {
        "Allowing continues this run once from the stopped point."
    }

    private enum AccessKind {
        case shell
        case fileRead
        case fileWrite
        case network
        case provider
    }

    private var accessKind: AccessKind {
        switch normalizedToolName {
        case "bash", "shell":
            return .shell
        case "read", "view":
            return .fileRead
        case "write", "create", "edit", "multiedit", "multi_edit":
            return .fileWrite
        case "webfetch", "websearch":
            return .network
        default:
            return .provider
        }
    }

    private var shellRoot: String? {
        Self.shellCommandRoot(actionDetail)?.lowercased()
    }

    private var actionDetail: String? {
        if let detail, !detail.isEmpty {
            return detail
        }
        guard let observedAction, !observedAction.isEmpty else {
            return nil
        }
        if let colon = observedAction.firstIndex(of: ":") {
            let value = observedAction[observedAction.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? observedAction : value
        }
        return observedAction
    }

    private var accessLabel: String {
        guard let toolName, !toolName.isEmpty else {
            return "provider access"
        }
        switch normalizedToolName {
        case "bash", "shell":
            return "Bash command"
        case "read", "view":
            return "file read"
        case "write", "create", "edit", "multiedit", "multi_edit":
            return "file change"
        case "webfetch", "websearch":
            return "web access"
        default:
            return "\(toolName) access"
        }
    }

    private var decisionGuidance: String {
        let normalizedTool = normalizedToolName
        let root = Self.shellCommandRoot(actionDetail)?.lowercased()
        if normalizedTool == "bash" || normalizedTool == "shell" {
            switch root {
            case "bq":
                return "allow only if this BigQuery command matches the task and should use the signed-in Google Cloud account and project."
            case "gcloud":
                return "allow only if this Google Cloud command matches the task and should use the signed-in Google Cloud account and project."
            case "curl", "wget":
                return "allow only if contacting that network destination is expected for this task."
            default:
                return "allow only if this shell command matches the task; it will run locally with this run's environment and credentials."
            }
        }

        switch normalizedTool {
        case "read", "view":
            return "allow only if the provider should read that path for this task."
        case "write", "create", "edit", "multiedit", "multi_edit":
            return "allow only if the provider should change that path for this task."
        case "webfetch", "websearch":
            return "allow only if that web or network access is expected for this task."
        default:
            return "allow only if this action matches the task and the requested access is expected."
        }
    }

    private var normalizedToolName: String {
        toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static let fieldStopMarkers = [
        "What ASTRA observed:",
        "Why approval is needed:",
        "What allowing does:",
        "What to check:",
        "Detail:",
        "Runtime grant:",
        "Provider detail:"
    ]

    private static func toolName(in text: String) -> String? {
        guard let range = text.range(of: "Permission requested for tool:", options: [.caseInsensitive]) else {
            return nil
        }
        let remainder = text[range.upperBound...]
        let endCandidates = [remainder.firstIndex(of: "."), remainder.firstIndex(of: "\n")].compactMap { $0 }
        let end = endCandidates.min() ?? remainder.endIndex
        let value = remainder[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func field(
        named marker: String,
        in text: String,
        stoppingBefore stopMarkers: [String]
    ) -> String? {
        guard let range = text.range(of: marker, options: [.caseInsensitive]) else {
            return nil
        }
        var value = String(text[range.upperBound...])
        var earliestStop: String.Index?
        for stopMarker in stopMarkers where stopMarker.caseInsensitiveCompare(marker) != .orderedSame {
            if let stopRange = value.range(of: stopMarker, options: [.caseInsensitive]),
               earliestStop.map({ stopRange.lowerBound < $0 }) ?? true {
                earliestStop = stopRange.lowerBound
            }
        }
        if let earliestStop {
            value = String(value[..<earliestStop])
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func observedActionDescription(toolName: String?, detail: String?) -> String? {
        guard let detail, !detail.isEmpty else {
            return nil
        }
        let toolName = toolName ?? "Provider"
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bash", "shell":
            return "Bash command: \(detail)"
        case "read", "view", "write", "create", "edit", "multiedit", "multi_edit":
            return "\(toolName) path: \(detail)"
        case "webfetch", "websearch":
            return "\(toolName) destination: \(detail)"
        default:
            return "\(toolName) request: \(detail)"
        }
    }

    private static func providerApprovalSummary(for detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let jsonStart = trimmed.firstIndex(of: "{")
        let leadingText = jsonStart.map { String(trimmed[..<$0]) } ?? trimmed
        var parts: [String] = []
        let compactLeadingText = compactText(leadingText, limit: 180)
        if !compactLeadingText.isEmpty {
            parts.append(compactLeadingText)
        }

        if let jsonStart,
           let object = PayloadFormatter.jsonObject(from: String(trimmed[jsonStart...])) as? [String: Any] {
            let data = object["data"] as? [String: Any] ?? object
            if let model = data["model"] as? String, !model.isEmpty {
                parts.append("Model: \(model)")
            }
            if let error = data["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty {
                    parts.append("Error: \(message)")
                }
                if let code = error["code"] as? String, !code.isEmpty {
                    parts.append("Code: \(code)")
                }
            }
        }

        return parts.isEmpty ? compactText(trimmed, limit: 260) : parts.joined(separator: ". ")
    }

    private static func compactText(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return "\(oneLine.prefix(limit))..."
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

struct NetworkAccessTechnicalDetailsPresentation: Hashable, Sendable {
    let subtitle: String
    let summary: String
    let facts: [RunFactPresentation]
    let rawPayload: String
    let copyText: String

    init(output: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.parseGoogleCloudPolicyResponse(from: trimmed)
        rawPayload = Self.prettyRawPayload(from: trimmed)

        if let parsed {
            let status = parsed.statusLabel ?? "Policy blocked"
            let service = parsed.service ?? "Google Cloud"
            subtitle = [status, service].filter { !$0.isEmpty }.joined(separator: " - ")
            summary = "Google Cloud blocked the request with \(parsed.control ?? "organization policy"). Use these fields when checking VPN, VPC Service Controls, or Cloud access policy."
            facts = Self.displayFacts(from: parsed)
            copyText = Self.copyText(from: parsed, rawPayload: rawPayload)
        } else {
            subtitle = "Provider response"
            summary = "The provider returned a network or policy error. The raw response is preserved for diagnostics."
            facts = []
            copyText = trimmed
        }
    }

    private struct ParsedPolicyResponse: Hashable, Sendable {
        var code: String?
        var status: String?
        var reason: String?
        var message: String?
        var service: String?
        var domain: String?
        var control: String?
        var identifier: String?
        var troubleshootToken: String?

        var statusLabel: String? {
            let statusText = status.map(Self.humanizedConstant)
            if let code, let statusText {
                return "\(code) \(statusText)"
            }
            return statusText ?? code
        }

        private static func humanizedConstant(_ value: String) -> String {
            let words = value
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }
            return words.joined(separator: " ")
        }
    }

    private static func parseGoogleCloudPolicyResponse(from output: String) -> ParsedPolicyResponse? {
        guard let object = PayloadFormatter.embeddedJSONObject(from: output),
              let error = googleCloudErrorObject(from: object) else {
            return nil
        }

        var response = ParsedPolicyResponse()
        response.code = stringValue(error["code"])
        response.status = stringValue(error["status"])
        response.message = stringValue(error["message"])

        if let details = error["details"] as? [[String: Any]] {
            for detail in details {
                if let violations = detail["violations"] as? [[String: Any]],
                   let violation = violations.first {
                    response.control = response.control ?? humanizedConstant(stringValue(violation["type"]) ?? "")
                    response.identifier = response.identifier ?? stringValue(violation["description"])
                }

                response.reason = response.reason ?? stringValue(detail["reason"])
                response.domain = response.domain ?? stringValue(detail["domain"])

                if let metadata = detail["metadata"] as? [String: Any] {
                    response.service = response.service ?? stringValue(metadata["service"])
                    response.identifier = response.identifier ??
                        stringValue(metadata["uid"]) ??
                        stringValue(metadata["vpcServiceControlsUniqueIdentifier"])
                    response.troubleshootToken = response.troubleshootToken ?? stringValue(metadata["troubleshootToken"])
                }
            }
        }

        response.identifier = response.identifier ?? identifierFromMessage(response.message)
        if response.control?.isEmpty == true {
            response.control = nil
        }
        return response
    }

    private static func googleCloudErrorObject(from object: Any) -> [String: Any]? {
        if let array = object as? [[String: Any]] {
            for item in array {
                if let nested = item["error"] as? [String: Any] {
                    return nested
                }
                if item["code"] != nil || item["status"] != nil || item["message"] != nil {
                    return item
                }
            }
            return nil
        }

        guard let dictionary = object as? [String: Any] else { return nil }
        if let nested = dictionary["error"] as? [String: Any] {
            return nested
        }
        if dictionary["code"] != nil || dictionary["status"] != nil || dictionary["message"] != nil {
            return dictionary
        }
        return nil
    }

    private static func displayFacts(from response: ParsedPolicyResponse) -> [RunFactPresentation] {
        var facts: [RunFactPresentation] = []
        appendFact("Status", response.statusLabel, to: &facts)
        appendFact("Reason", response.reason.map(humanizedConstant), to: &facts)
        appendFact("Service", response.service, to: &facts, isMonospaced: true)
        appendFact("Control", response.control, to: &facts)
        appendFact("Identifier", response.identifier.map(compactDiagnosticValue), to: &facts, isMonospaced: true)
        appendFact("Troubleshoot token", response.troubleshootToken.map(compactDiagnosticValue), to: &facts, isMonospaced: true)
        appendFact("Domain", response.domain, to: &facts, isMonospaced: true)
        return facts
    }

    private static func copyText(from response: ParsedPolicyResponse, rawPayload: String) -> String {
        var lines = ["Google Cloud policy response"]
        appendCopyLine("Status", response.statusLabel, to: &lines)
        appendCopyLine("Reason", response.reason.map(humanizedConstant), to: &lines)
        appendCopyLine("Service", response.service, to: &lines)
        appendCopyLine("Control", response.control, to: &lines)
        appendCopyLine("Identifier", response.identifier, to: &lines)
        appendCopyLine("Troubleshoot token", response.troubleshootToken, to: &lines)
        appendCopyLine("Domain", response.domain, to: &lines)
        if !rawPayload.isEmpty {
            lines.append("")
            lines.append("Raw response:")
            lines.append(rawPayload)
        }
        return lines.joined(separator: "\n")
    }

    private static func prettyRawPayload(from output: String) -> String {
        if let object = PayloadFormatter.embeddedJSONObject(from: output),
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: data, encoding: .utf8) {
            let prefix = outputPrefix(beforeEmbeddedJSONIn: output)
            return prefix.isEmpty ? pretty : "\(prefix)\n\(pretty)"
        }
        return output
    }

    private static func outputPrefix(beforeEmbeddedJSONIn output: String) -> String {
        guard let index = output.indices.first(where: { output[$0] == "{" || output[$0] == "[" }) else {
            return ""
        }
        return String(output[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func identifierFromMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let marker = "vpcServiceControlsUniqueIdentifier:"
        guard let range = message.range(of: marker) else { return nil }
        return message[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
    }

    private static func appendFact(
        _ title: String,
        _ value: String?,
        to facts: inout [RunFactPresentation],
        isMonospaced: Bool = false
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        facts.append(.init(title: title, value: value, isMonospaced: isMonospaced))
    }

    private static func appendCopyLine(_ title: String, _ value: String?, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        lines.append("\(title): \(value)")
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as Int:
            String(value)
        case let value as Double:
            String(value)
        default:
            nil
        }
    }

    private static func humanizedConstant(_ value: String) -> String {
        let known = [
            "VPC_SERVICE_CONTROLS": "VPC Service Controls"
        ]
        if let knownValue = known[value] {
            return knownValue
        }
        let words = value
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
        return words.joined(separator: " ")
    }

    private static func compactDiagnosticValue(_ value: String) -> String {
        guard value.count > 72 else { return value }
        return "\(value.prefix(34))...\(value.suffix(18))"
    }
}

private func appendStringFact(
    _ title: String,
    key: String,
    object: [String: Any],
    facts: inout [RunFactPresentation]
) {
    guard let value = object[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }
    facts.append(.init(title: title, value: value))
}

private func appendIntFact(
    _ title: String,
    key: String,
    object: [String: Any],
    facts: inout [RunFactPresentation]
) {
    guard let value = object[key] as? Int else { return }
    facts.append(.init(title: title, value: String(value)))
}

private func appendBoolFact(
    _ title: String,
    key: String,
    object: [String: Any],
    facts: inout [RunFactPresentation]
) {
    guard let value = object[key] as? Bool else { return }
    facts.append(.init(title: title, value: value ? "Yes" : "No"))
}

private func appendListFact(
    _ title: String,
    key: String,
    object: [String: Any],
    facts: inout [RunFactPresentation],
    limit: Int,
    isMonospaced: Bool = false
) {
    guard let values = object[key] as? [String], !values.isEmpty else { return }
    facts.append(.init(title: title, value: compactList(values, limit: limit), isMonospaced: isMonospaced))
}

private func compactList(_ values: [String], limit: Int = 8, empty: String = "") -> String {
    guard !values.isEmpty else { return empty }
    let prefix = values.prefix(limit).joined(separator: ", ")
    let remaining = values.count - min(values.count, limit)
    return remaining > 0 ? "\(prefix) +\(remaining) more" : prefix
}
