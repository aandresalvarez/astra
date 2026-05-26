import Foundation

enum BrowserBridgeActionMetadata {
    static func enriched(_ actions: [[String: Any]]) -> [[String: Any]] {
        actions.map(enriched)
    }

    static func enriched(_ action: [String: Any]) -> [String: Any] {
        guard let path = action["path"] as? String else { return action }
        var object = action
        object["category"] = category(for: path)
        object["riskLevel"] = riskLevel(for: path)
        object["confirmation"] = confirmationPolicy(for: path)
        object["preferredUse"] = preferredUse(for: path)
        return object
    }

    static func category(for path: String) -> String {
        switch path {
        case "/health":
            return "status"
        case "/actions":
            return "discovery"
        case "/trace", "/benchmark":
            return "diagnostics"
        case "/analyze", "/preflight", "/snapshot", "/readPage", "/findControl", "/locator":
            return "inspection"
        case "/verifyText", "/waitSaved", "/waitForText", "/waitForSelector":
            return "verification"
        case "/navigate", "/open", "/googleDriveOpen":
            return "navigation"
        case "/googleDocsReadVisiblePage", "/googleDocsReadDocument", "/googleDocsFind":
            return "site-read"
        case "/googleFindReplace", "/googleDocsInsert", "/googleDocsReplaceDocument":
            return "site-mutation"
        case "/click", "/doubleClick", "/clickControl", "/type", "/fill", "/setValue", "/replaceText", "/keypress", "/text", "/act", "/batch":
            return "mutation"
        default:
            return "other"
        }
    }

    static func riskLevel(for path: String) -> String {
        switch path {
        case "/health", "/actions", "/trace", "/benchmark", "/analyze", "/preflight", "/snapshot", "/readPage", "/findControl", "/locator", "/verifyText", "/waitSaved", "/waitForText", "/waitForSelector", "/googleDocsReadVisiblePage", "/googleDocsReadDocument", "/googleDocsFind":
            return "read-only"
        case "/navigate", "/open", "/googleDriveOpen":
            return "navigation"
        case "/type", "/fill", "/setValue", "/replaceText", "/click", "/doubleClick", "/clickControl", "/keypress", "/text", "/act", "/batch", "/googleFindReplace", "/googleDocsInsert":
            return "mutating"
        case "/googleDocsReplaceDocument":
            return "high-impact"
        default:
            return "unknown"
        }
    }

    static func confirmationPolicy(for path: String) -> String {
        switch riskLevel(for: path) {
        case "read-only":
            return "not-required"
        case "navigation":
            return "required-for-external-or-high-impact-targets"
        case "mutating", "high-impact":
            return "required-for-dangerous-targets"
        default:
            return "unknown"
        }
    }

    static func preferredUse(for path: String) -> String {
        switch path {
        case "/analyze":
            return "Build a reusable action map before choosing controls."
        case "/preflight":
            return "Validate a cached control action without executing it."
        case "/trace":
            return "Inspect the last browser failure or loop before retrying."
        case "/readPage":
            return "Answer questions about visible page content."
        case "/googleDriveOpen":
            return "Open Drive files by visible name instead of probing rows."
        case "/googleDocsReplaceDocument":
            return "Replace a full Google Docs document through the guarded helper."
        default:
            return "Use when the action matches the current page and policy allows it."
        }
    }
}

enum BrowserBridgeRecoveryHints {
    static func attach(
        to response: inout [String: Any],
        error code: String,
        action: String? = nil,
        analysisID: String? = nil,
        controlID: String? = nil,
        controlLabel: String? = nil,
        validActions: [String] = []
    ) {
        guard let recovery = recoveryObject(
            error: code,
            action: action,
            analysisID: analysisID,
            controlID: controlID,
            controlLabel: controlLabel,
            validActions: validActions
        ) else { return }

        response["recovery"] = recovery
        if let command = recovery["nextCommand"] as? String, !command.isEmpty {
            response["nextCommand"] = command
        }
        if response["suggestedNextActions"] == nil,
           let suggestions = recovery["suggestedNextActions"] {
            response["suggestedNextActions"] = suggestions
        }
    }

    static func recoveryObject(
        error code: String,
        action: String? = nil,
        analysisID: String? = nil,
        controlID: String? = nil,
        controlLabel: String? = nil,
        validActions: [String] = []
    ) -> [String: Any]? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let label = controlLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryCommand: String
        if let label, !label.isEmpty {
            queryCommand = "astra-browser analyze --query \(shellQuote(label))"
        } else {
            queryCommand = "astra-browser analyze"
        }

        let command: String?
        let summary: String
        let kind: String

        switch normalized {
        case "stale_analysis", "control_changed":
            command = queryCommand
            summary = "The cached browser action map is stale. Re-analyze the live page before acting again."
            kind = "reanalyze"
        case "target_obscured", "target_not_actionable", "element_not_visible", "element_disabled":
            command = "astra-browser analyze --full --debug"
            summary = "The target failed live actionability checks. Inspect the live controls and obstruction evidence before retrying."
            kind = "inspect"
        case "unsupported_action":
            if let fallback = fallbackActionCommand(analysisID: analysisID, controlID: controlID, validActions: validActions) {
                command = fallback
                summary = "The requested action is not supported by this control. Use one of the valid actions returned by analysis."
            } else {
                command = queryCommand
                summary = "The requested action is not supported by this control. Re-analyze and choose a valid action."
            }
            kind = "choose-supported-action"
        case "dangerous_confirmation_required":
            command = nil
            summary = "This browser action needs explicit user confirmation in chat before retrying with dangerous-action permission."
            kind = "ask-confirmation"
        case "credential_input_blocked", "mfa_input_blocked":
            command = nil
            summary = "ASTRA will not enter secrets or verification codes. Ask the user to enter the value directly in the browser."
            kind = "user-direct-entry"
        case "browser_action_budget_exceeded":
            command = "astra-browser trace"
            summary = "Browser control hit a loop or budget guard. Inspect the trace before trying a different strategy."
            kind = "inspect-trace"
        case "browser_bridge_disabled":
            command = "astra-browser health"
            summary = "Agent browser control is disabled or not attached to this task. Enable the Shelf bridge, then check health."
            kind = "check-health"
        case "controlled_browser_unavailable", "google_docs_controlled_browser_required":
            command = "astra-browser health"
            summary = "This helper needs Controlled Browser mode. Open or repair the controlled browser, then check health before retrying."
            kind = "check-controlled-browser"
        case "missing_analysis_or_control":
            command = "astra-browser analyze"
            summary = "This action needs an analysisID and controlID. Build an action map first."
            kind = "reanalyze"
        case "not_found":
            command = "astra-browser actions"
            summary = "The requested browser bridge endpoint is unavailable. List supported actions before retrying."
            kind = "discover-actions"
        case "browser_bridge_error":
            command = "astra-browser trace"
            summary = "The browser bridge raised an internal error. Inspect the trace and latest failure evidence before retrying."
            kind = "inspect-trace"
        default:
            command = nil
            summary = "Stop repeating the same browser action. Inspect `astra-browser trace` or re-run `astra-browser analyze` if page state may have changed."
            kind = "stop-repeat"
        }

        var object: [String: Any] = [
            "kind": kind,
            "summary": summary
        ]
        if let action, !action.isEmpty {
            object["failedAction"] = action
        }
        if let command, !command.isEmpty {
            object["nextCommand"] = command
            object["suggestedNextActions"] = [
                [
                    "kind": "command",
                    "command": command,
                    "reason": summary
                ]
            ]
        } else {
            object["suggestedNextActions"] = [
                [
                    "kind": "user",
                    "reason": summary
                ]
            ]
        }
        return object
    }

    private static func fallbackActionCommand(
        analysisID: String?,
        controlID: String?,
        validActions: [String]
    ) -> String? {
        guard let analysisID, !analysisID.isEmpty,
              let controlID, !controlID.isEmpty else { return nil }
        for action in validActions {
            if let commandName = cliCommandName(for: action) {
                return "astra-browser \(commandName) --analysis \(shellQuote(analysisID)) --control \(shellQuote(controlID))"
            }
        }
        return nil
    }

    private static func cliCommandName(for action: String) -> String? {
        switch action {
        case BrowserActionKind.open.rawValue:
            return "open"
        case BrowserActionKind.doubleClick.rawValue:
            return "double-click"
        case BrowserActionKind.click.rawValue:
            return "click"
        case BrowserActionKind.fill.rawValue:
            return "fill"
        case BrowserActionKind.setValue.rawValue:
            return "set-value"
        default:
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum BrowserBridgeStatusSummary {
    static func build(
        bridgeEnabled: Bool,
        hasEndpoint: Bool,
        backend: String,
        controlledState: String,
        controlledRunning: Bool,
        hasDebugPort: Bool,
        activeAdapterCount: Int,
        lastFailure: String?
    ) -> [String: Any] {
        let bridgeState: String
        if !bridgeEnabled {
            bridgeState = "disabled"
        } else if hasEndpoint {
            bridgeState = "connected"
        } else {
            bridgeState = "starting"
        }

        let readiness: String
        if let lastFailure, !lastFailure.isEmpty {
            readiness = "needs_attention"
        } else if bridgeState == "connected" && (!backend.lowercased().contains("controlled") || controlledRunning) {
            readiness = "ready"
        } else if bridgeState == "disabled" {
            readiness = "disabled"
        } else {
            readiness = "degraded"
        }

        var object: [String: Any] = [
            "readiness": readiness,
            "bridge": bridgeState,
            "backend": backend,
            "controlledBrowser": controlledState,
            "controlledBrowserRunning": controlledRunning,
            "debugPort": hasDebugPort ? "available" : "unavailable",
            "activeAdapterCount": activeAdapterCount
        ]
        if let lastFailure, !lastFailure.isEmpty {
            object["lastFailure"] = lastFailure
        }
        return object
    }
}
