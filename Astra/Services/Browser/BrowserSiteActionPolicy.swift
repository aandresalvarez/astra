import Foundation

enum BrowserSiteActionPolicy {
    static func denialReason(
        route: ShelfBrowserBridgeRoute,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool = false
    ) -> String? {
        let enforceGitHubReadOnly = githubReadOnlyMode || GitHubBrowserAdapter.isEnabled(in: enabledBrowserAdapters)
        guard enforceGitHubReadOnly,
              GitHubBrowserAdapter.matches(pageURL: currentURL),
              !route.isAllowedInGitHubReadOnlyContext else {
            return nil
        }
        return "GitHub browser control is read-only. Use ASTRA host-control GitHub MCP for GitHub operations instead of browser actions that can mutate github.com."
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
             .text,
             .batch:
            return false
        }
    }
}
