import Foundation
import Testing
@testable import ASTRA

/// Slice 8: the WebView CSP must stay locked — bundled assets only, no network, no remote, no
/// arbitrary inline script. These assert the policy can't silently loosen.
@Suite("Workspace App WebView CSP (Slice 8)")
struct WorkspaceAppWebViewCSPTests {
    private var policy: String { WorkspaceAppWebViewCSP.policy }

    @Test("the policy denies everything by default")
    func defaultDenies() {
        #expect(policy.contains("default-src 'none'"))
    }

    @Test("no network egress is permitted from a widget")
    func noNetwork() {
        #expect(policy.contains("connect-src 'none'"))
        #expect(!policy.contains("http://"))
        #expect(!policy.contains("https://"))
    }

    @Test("no wildcard source is allowed")
    func noWildcard() {
        #expect(!policy.contains("*"))
    }

    @Test("scripts are bundled-only — no inline or eval imported JS")
    func scriptsBundledOnly() {
        let scriptSrc = WorkspaceAppWebViewCSP.directives.first { $0.hasPrefix("script-src") }
        #expect(scriptSrc == "script-src 'self'")
        #expect(!policy.contains("unsafe-eval"))
        // 'unsafe-inline' may only appear for styles, never for scripts.
        #expect(scriptSrc?.contains("unsafe-inline") != true)
    }

    @Test("framing and base/form hijacking are blocked")
    func framingBlocked() {
        #expect(policy.contains("frame-ancestors 'none'"))
        #expect(policy.contains("base-uri 'none'"))
        #expect(policy.contains("form-action 'none'"))
    }

    @Test("the meta tag carries the policy verbatim")
    func metaTagWrapsPolicy() {
        let tag = WorkspaceAppWebViewCSP.metaTag()
        #expect(tag.contains("http-equiv=\"Content-Security-Policy\""))
        #expect(tag.contains(policy))
    }
}
