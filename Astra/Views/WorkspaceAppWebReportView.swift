import SwiftUI
import WebKit

/// Sandboxed WKWebView host for a workspace app's HTML surface — the static `htmlReport`,
/// the vetted `chartInteractive` renderer, and (Phase 1) MODEL-authored dynamic HTML apps.
///
/// The boundary Swift enforces, precisely (it holds regardless of what the HTML contains):
/// - **No network egress.** The document CSP is `default-src 'none'` (plus the interactive
///   shells' `'unsafe-inline'` script/style), so fetch/XHR/WebSocket/EventSource/beacon and
///   every external resource are blocked.
/// - **No JS↔native bridge.** No `WKScriptMessageHandler` is registered, so page JS has no
///   channel to native code or app data.
/// - **No navigation or window creation.** The nav delegate cancels every load that isn't the
///   initial in-memory `about:` load; the UI delegate returns nil for `window.open`.
/// - **No file panels or JS dialogs.** The UI delegate denies open panels (so `<input type=file>`
///   can't read disk) and dismisses alert/confirm/prompt.
/// - **No persistence.** The data store is `.nonPersistent()` and `baseURL` is nil.
///
/// What is NOT claimed: a user-gesture `navigator.clipboard.writeText` can still run — but with
/// no network egress there is no exfiltration channel, so the residual risk is local clipboard
/// nuisance, not data leakage. Legitimate "copy result" buttons rely on it, so it stays allowed.
struct WorkspaceAppWebReportView: NSViewRepresentable {
    let html: String
    /// JavaScript stays OFF by default. The vetted `chartInteractive` renderer and Phase 1 HTML
    /// apps opt in (locked CSP, no native bridge, no network — see the type doc).
    var allowsJavaScript = false
    /// Phase 2/5 data + workflow bridge. When non-nil, an `astraAppBridge` message handler + the
    /// `astra.*` JS API are registered so the page can read/write its OWN governed storage and
    /// trigger its OWN declared workflow actions through these closures (which route to the existing
    /// action executor). Nil for charts/static reports and pure-UI HTML apps — those keep the
    /// no-native-bridge posture. See `WorkspaceAppDataBridge`.
    var onBridgeRequest: WorkspaceAppDataBridge.Handlers?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        if let onBridgeRequest {
            // Vetted, allowlisted, local-only data + workflow channel (no network). The handler is
            // retained by the userContentController; the injected script runs before the app's own JS.
            let handler = WorkspaceAppDataBridgeHandler(handlers: onBridgeRequest)
            context.coordinator.bridgeHandler = handler
            configuration.userContentController.addScriptMessageHandler(
                handler, contentWorld: .page, name: WorkspaceAppDataBridge.handlerName
            )
            configuration.userContentController.addUserScript(WKUserScript(
                source: WorkspaceAppDataBridge.injectedScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let webView = WorkspaceAppNonDroppingWebView(frame: .zero, configuration: configuration)
        // Refuse drag-and-drop so a dropped file can't reach page JS (FileReader → astra.insert).
        // The CSP already blocks network egress, but this stops a dropped file from entering the
        // app's own storage at all. Best-effort on top of the subclass overrides below.
        webView.unregisterDraggedTypes()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep the bridge allowlist current: refresh the handler's closures (they capture the live
        // manifest) so an app refinement that changes storage/actions/permission takes effect even
        // when the HTML itself is unchanged. If a still-present handler's app no longer grants a bridge
        // (onBridgeRequest now nil on a reused WebView), install the fail-closed deny-all handlers so a
        // stale `astra.*` call can't reach the prior app — defense in depth behind `.id(bridgeEligible)`,
        // which already recreates the WebView when bridge presence flips.
        if let bridgeHandler = context.coordinator.bridgeHandler {
            bridgeHandler.handlers = onBridgeRequest ?? WorkspaceAppDataBridge.denyAll
        }
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        /// Retains the Phase 2 data-bridge handler for the WebView's lifetime (nil when no bridge).
        var bridgeHandler: WorkspaceAppDataBridgeHandler?

        // Allow only Swift-initiated in-memory loads — `loadHTMLString(baseURL: nil)` resolves
        // to an `about:` URL, including reloads when the data changes. Cancel everything else:
        // link clicks, form submits, and — now that the interactive renderer runs JS — any
        // script-initiated navigation to a real URL (http/https/file/...). So even if a script
        // tried `location = "https://attacker/..."`, the nav layer blocks it independently of CSP.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme
            let isInMemoryLoad = scheme == nil || scheme == "about"
            decisionHandler(navigationAction.navigationType == .other && isInMemoryLoad ? .allow : .cancel)
        }

        // Defense in depth for drag/drop: WKWebView's internal content view can register itself as a
        // drop destination after the page loads (the outer view's `unregisterDraggedTypes()` doesn't
        // cover it). Recursively strip dragged types once loading finishes so a dropped file can't
        // reach page JS (FileReader → astra.insert). The document-level guard in the HTML shell and
        // the no-network CSP are the other layers.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.unregisterDragRecursively(webView)
        }

        static func unregisterDragRecursively(_ view: NSView) {
            view.unregisterDraggedTypes()
            for subview in view.subviews { unregisterDragRecursively(subview) }
        }

        // Deny `window.open` / target=_blank popups: returning nil means no child WebView is
        // created (and any URL it carried never loads).
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        // Deny the native file-open panel, so `<input type="file">` can never read disk. Making
        // this explicit (vs. relying on the absence of a UI delegate) keeps the no-filesystem
        // guarantee a deliberate policy with a regression test, not an assumed WebKit default.
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            completionHandler(nil)
        }

        // Silently dismiss JS dialogs — a sandboxed app surface must not drive modal UI.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(false)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// A WKWebView that refuses ALL drag-and-drop. A sandboxed app surface has no legitimate need to
/// accept dropped files, and a drop could otherwise hand a local file to page JS (FileReader →
/// `astra.insert`). The drag NSView methods are overridden to reject, in addition to
/// `unregisterDraggedTypes()` at construction.
final class WorkspaceAppNonDroppingWebView: WKWebView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// Card chrome around a sandboxed HTML report, matching the other native surface widgets.
struct WorkspaceAppWebReportCard: View {
    let report: WorkspaceAppWebReportPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.lagunita)
                Text(report.label)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            WorkspaceAppWebReportView(html: report.html, allowsJavaScript: report.allowsJavaScript)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
