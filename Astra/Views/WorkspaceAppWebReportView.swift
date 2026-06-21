import SwiftUI
import WebKit

/// Sandboxed WKWebView host for a workspace app's HTML report — the flexible-local-app
/// visualization surface. Hardened so Swift keeps owning everything: JavaScript is
/// disabled, the data store is non-persistent, there are NO JS↔native message handlers,
/// and every navigation after the initial in-memory load is cancelled. Combined with the
/// document's `default-src 'none'` CSP and `baseURL: nil`, the report can only display
/// the Swift-built HTML — it can never reach the network or escape the sandbox.
struct WorkspaceAppWebReportView: NSViewRepresentable {
    let html: String
    /// JavaScript stays OFF by default. Only the vetted `chartInteractive` renderer opts in
    /// (Swift-authored inline script, escaped-JSON data, no network, no native bridge).
    var allowsJavaScript = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

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
    }
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
