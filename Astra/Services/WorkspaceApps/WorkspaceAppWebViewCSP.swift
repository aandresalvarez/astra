import Foundation

/// Slice 8: the Content-Security-Policy every Workspace App WebView renderer MUST apply to the HTML
/// it renders. Locks rendering to ASTRA-bundled assets only — no remote loads, no network egress,
/// no framing, no arbitrary inline script. Combined with the renderer allowlist
/// (`WorkspaceAppWebViewBridge.allowedRenderers`) and the per-widget action allowlist, an
/// ASTRA-known renderer (mermaidDiagram / htmlReport / chartComposite) can only run bundled JS/CSS
/// against the data the bridge hands it — never imported custom JavaScript and never the network.
enum WorkspaceAppWebViewCSP {
    /// The directives, locked down. `script-src 'self'` means ONLY bundled scripts run — no
    /// inline/imported JS; `connect-src 'none'` blocks all network from a widget.
    static let directives: [String] = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",   // renderers inline computed styles; no scripts here
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'none'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ]

    /// The full `Content-Security-Policy` header / meta value.
    static var policy: String { directives.joined(separator: "; ") }

    /// The `<meta http-equiv>` tag to inject into a rendered HTML `<head>`.
    static func metaTag() -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }
}
