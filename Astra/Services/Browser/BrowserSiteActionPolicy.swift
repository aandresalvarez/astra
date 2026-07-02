import Foundation

enum BrowserSiteActionPolicy {
    static let gitHubReadOnlyDenialReason = "GitHub browser control is read-only. Use ASTRA host-control GitHub MCP for GitHub operations instead of browser actions that can mutate github.com."

    static func denialReason(
        route: ShelfBrowserBridgeRoute,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool = false
    ) -> String? {
        guard enforcesGitHubReadOnly(githubReadOnlyMode: githubReadOnlyMode, enabledBrowserAdapters: enabledBrowserAdapters),
              GitHubBrowserAdapter.matches(pageURL: currentURL),
              !route.isAllowedInGitHubReadOnlyContext else {
            return nil
        }
        return gitHubReadOnlyDenialReason
    }

    static func denialReason(
        batchAction action: String,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool = false
    ) -> String? {
        guard let route = ShelfBrowserBridgeCommandRouter.route(batchAction: action) else {
            return nil
        }
        return denialReason(
            route: route,
            currentURL: currentURL,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        )
    }

    static func routeDenialResponse(
        route: ShelfBrowserBridgeRoute,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool
    ) -> BrowserBridgeResponse? {
        guard let reason = denialReason(
            route: route,
            currentURL: currentURL,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        ) else { return nil }
        return .json(denialPayload(reason: reason, includeRecoveryHints: true), statusCode: 403)
    }

    static func batchDenialResult(
        action: String,
        normalizedAction: String,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool
    ) -> [String: Any]? {
        guard let reason = denialReason(
            batchAction: normalizedAction,
            currentURL: currentURL,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        ) else { return nil }
        return denialPayload(action: action, reason: reason, includeRecoveryHints: false)
    }

    static func openControlDenialResult(
        action: String,
        control: BrowserControl,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool
    ) -> [String: Any]? {
        guard let reason = openControlDenialReason(
            control: control,
            currentURL: currentURL,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        ) else { return nil }
        return denialPayload(action: action, reason: reason, includeRecoveryHints: false)
    }

    private static func openControlDenialReason(
        control: BrowserControl,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool
    ) -> String? {
        guard enforcesGitHubReadOnly(githubReadOnlyMode: githubReadOnlyMode, enabledBrowserAdapters: enabledBrowserAdapters),
              GitHubBrowserAdapter.matches(pageURL: currentURL) else {
            return nil
        }
        guard GitHubBrowserAdapter.isReadOnlyOpenControl(
            pageURL: currentURL,
            selector: control.selector,
            label: control.label,
            name: control.name,
            role: control.role,
            tag: control.tag,
            href: control.href
        ) else {
            return gitHubReadOnlyDenialReason
        }
        return nil
    }

    private static func enforcesGitHubReadOnly(
        githubReadOnlyMode: Bool,
        enabledBrowserAdapters: Set<String>
    ) -> Bool {
        githubReadOnlyMode || GitHubBrowserAdapter.isEnabled(in: enabledBrowserAdapters)
    }

    private static func denialPayload(
        action: String? = nil,
        reason: String,
        includeRecoveryHints: Bool
    ) -> [String: Any] {
        var response: [String: Any] = [
            "ok": false,
            "error": "site_action_not_allowed",
            "reason": reason,
            "adapterID": BrowserSiteAdapterID.github
        ]
        if let action {
            response["action"] = action
        }
        if includeRecoveryHints {
            BrowserBridgeRecoveryHints.attach(to: &response, error: "site_action_not_allowed")
        }
        return response
    }
}

extension ShelfBrowserBridgeRoute {
    var isAllowedInGitHubReadOnlyContext: Bool {
        switch self {
        case .health,
             .actions,
             .analyze,
             .trace,
             .benchmark,
             .snapshot,
             .readPage,
             .findControl,
             .locator,
             .verifyText,
             .waitForText,
             .waitForSelector,
             .navigate,
             .open:
            return true
        case .preflight,
             .type,
             .setValue,
             .replaceText,
             .clickControl,
             .waitSaved,
             .googleFindReplace,
             .googleDocsFind,
             .googleDocsInsert,
             .googleDocsReadVisiblePage,
             .googleDocsReadDocument,
             .googleDocsReplaceDocument,
             .googleDriveOpen,
             .act,
             .click,
             .doubleClick,
             .fill,
             .keypress,
             .text:
            return false
        case .batch:
            return true
        }
    }

    static func browserRoute(forBatchAction action: String) -> ShelfBrowserBridgeRoute? {
        ShelfBrowserBridgeCommandRouter.route(batchAction: action)
    }
}
