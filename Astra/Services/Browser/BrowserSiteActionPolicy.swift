import Foundation

enum BrowserSiteActionPolicy {
    static let gitHubReadOnlyDenialReason = "GitHub browser control is read-only. Use ASTRA host-control GitHub MCP for GitHub operations instead of browser actions that can mutate github.com."

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
        return gitHubReadOnlyDenialReason
    }

    static func denialReason(
        batchAction action: String,
        currentURL: String,
        enabledBrowserAdapters: Set<String>,
        githubReadOnlyMode: Bool = false
    ) -> String? {
        guard let route = ShelfBrowserBridgeRoute.browserRoute(forBatchAction: action) else {
            return nil
        }
        return denialReason(
            route: route,
            currentURL: currentURL,
            enabledBrowserAdapters: enabledBrowserAdapters,
            githubReadOnlyMode: githubReadOnlyMode
        )
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
             .navigate:
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
             .open,
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
        switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "analyze":
            return .analyze
        case "preflight":
            return .preflight
        case "navigate":
            return .navigate
        case "click":
            return .click
        case "open":
            return .open
        case "doubleclick", "double-click", "double_click":
            return .doubleClick
        case "type":
            return .type
        case "setvalue", "set-value":
            return .setValue
        case "fill":
            return .fill
        case "replacetext", "replace-text":
            return .replaceText
        case "findcontrol", "find-control":
            return .findControl
        case "clickcontrol", "click-control":
            return .clickControl
        case "verifytext", "verify-text":
            return .verifyText
        case "waitsaved", "wait-saved":
            return .waitSaved
        case "googlefindreplace", "google-find-replace":
            return .googleFindReplace
        case "googledocsfind", "google-docs-find":
            return .googleDocsFind
        case "googledocsinsert", "google-docs-insert":
            return .googleDocsInsert
        case "googledocsreaddocument", "google-docs-read-document", "googledocsread", "google-docs-read":
            return .googleDocsReadDocument
        case "googledocsreadvisiblepage", "google-docs-read-visible-page", "googledocsreadvisible", "google-docs-read-visible", "googledocsreadpage", "google-docs-read-page":
            return .googleDocsReadVisiblePage
        case "googledocsreplacedocument", "google-docs-replace-document":
            return .googleDocsReplaceDocument
        case "googledriveopen", "google-drive-open", "drive-open":
            return .googleDriveOpen
        case "act":
            return .act
        case "keypress":
            return .keypress
        case "text", "inserttext":
            return .text
        case "waitfortext", "wait-text":
            return .waitForText
        case "waitforselector", "wait-selector":
            return .waitForSelector
        case "snapshot":
            return .snapshot
        default:
            return nil
        }
    }
}
