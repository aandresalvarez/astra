import Foundation
import Testing
@testable import ASTRA

/// Slice 8: the WebView bridge is the trust boundary between untrusted in-widget
/// JavaScript and the governed action runtime. A widget may invoke ONLY the actions in
/// its own `allowedActions` allowlist, and only ASTRA-known renderers are permitted
/// (no arbitrary imported JS). These adversarial tests lock that boundary.
@Suite("Workspace App WebView Bridge (Slice 8)")
struct WorkspaceAppWebViewBridgeTests {
    /// A valid manifest with TWO webView widgets that each allow a DIFFERENT action,
    /// so cross-widget isolation is testable.
    private static func bridgeManifest() -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
        manifest.actions = [
            WorkspaceAppActionSpec(id: "refresh_panel", type: "appStorage.query", label: "Refresh"),
            WorkspaceAppActionSpec(id: "export_secret", type: "appStorage.query", label: "Export"),
            WorkspaceAppActionSpec(id: "add_item", type: "appStorage.insert", label: "Add", table: "items")
        ]
        manifest.views = [
            WorkspaceAppViewSpec(
                id: "dashboard",
                type: "dashboard",
                title: "Dashboard",
                widgets: [
                    WorkspaceAppWidgetSpec(
                        id: "panel_a", type: "webView", label: "Panel A",
                        webRenderer: "htmlReport", allowedActions: ["refresh_panel"]
                    ),
                    WorkspaceAppWidgetSpec(
                        id: "panel_b", type: "webView", label: "Panel B",
                        webRenderer: "chartComposite", allowedActions: ["export_secret"]
                    )
                ]
            )
        ]
        return manifest
    }

    @Test("the fixture manifest is valid (so blocks below come from the bridge, not validation)")
    func fixtureIsValid() {
        #expect(WorkspaceAppManifestValidator.validate(Self.bridgeManifest()).isValid)
    }

    @Test("a widget may invoke an action in its own allowlist")
    func allowsActionInAllowlist() {
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "panel_a", actionID: "refresh_panel"),
            manifest: Self.bridgeManifest()
        )
        #expect(result.isAllowed)
        #expect(result.action?.id == "refresh_panel")
    }

    @Test("a widget may NOT invoke an action outside its allowlist (cross-widget isolation)")
    func blocksActionFromAnotherWidgetsAllowlist() {
        // export_secret is real and allowed for panel_b, but NOT for panel_a.
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "panel_a", actionID: "export_secret"),
            manifest: Self.bridgeManifest()
        )
        #expect(!result.isAllowed)
        #expect(result.action == nil)
        #expect(result.issue?.path == "/actionID")
        #expect(result.issue?.message.contains("not allowed") == true)
    }

    @Test("a request from an unknown widget is blocked")
    func blocksUnknownWidget() {
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "ghost", actionID: "refresh_panel"),
            manifest: Self.bridgeManifest()
        )
        #expect(!result.isAllowed)
        #expect(result.issue?.path == "/widgetID")
    }

    @Test("a non-webView widget cannot be used as a bridge source")
    func blocksNonWebViewWidget() {
        var manifest = Self.bridgeManifest()
        // A metric widget with the same id as a bridge request must NOT be addressable.
        manifest.views[0].widgets.append(
            WorkspaceAppWidgetSpec(id: "metric_panel", type: "metric", label: "Count", table: "items", aggregation: "count")
        )
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "metric_panel", actionID: "refresh_panel"),
            manifest: manifest
        )
        #expect(!result.isAllowed)
        #expect(result.issue?.path == "/widgetID")  // not a webView widget -> unknown
    }

    @Test("an allowlisted action that no longer exists is blocked (defense in depth)")
    func blocksStaleAllowlistedAction() {
        var manifest = Self.bridgeManifest()
        // Allowlist references an action id that isn't in the manifest's actions.
        manifest.views[0].widgets[0].allowedActions = ["refresh_panel", "phantom"]
        manifest.actions = manifest.actions.filter { $0.id != "phantom" }
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "panel_a", actionID: "phantom"),
            manifest: manifest
        )
        // Manifest is now INVALID (allowlist references unknown action), so the bridge
        // refuses at the manifest gate before any action lookup.
        #expect(!result.isAllowed)
        #expect(result.issue?.path == "/manifest")
    }

    @Test("an invalid manifest is refused outright")
    func blocksInvalidManifest() {
        var manifest = Self.bridgeManifest()
        manifest.app.id = ""  // blank id -> invalid
        let result = WorkspaceAppWebViewBridge.validate(
            WorkspaceAppWebViewBridgeRequest(widgetID: "panel_a", actionID: "refresh_panel"),
            manifest: manifest
        )
        #expect(!result.isAllowed)
        #expect(result.issue?.path == "/manifest")
    }

    // MARK: - Renderer allowlist (single source of truth)

    @Test("only ASTRA-known renderers are permitted, and the validator shares the bridge's allowlist")
    func rendererAllowlistIsSharedAndClosed() {
        // chartInteractive is the one JS renderer, but it's a vetted Swift-authored script —
        // arbitrary/imported renderers are still rejected (see customJavaScript below).
        #expect(WorkspaceAppWebViewBridge.allowedRenderers == ["htmlReport", "chartComposite", "chartInteractive"])
        // mermaidDiagram was removed (needs a bundled lib; native diagram widget covers it).
        #expect(!WorkspaceAppWebViewBridge.allowedRenderers.contains("mermaidDiagram"))

        var manifest = Self.bridgeManifest()
        manifest.views[0].widgets[0].webRenderer = "customJavaScript"  // arbitrary JS renderer
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/views/0/widgets/0/webRenderer" && $0.message.contains("not allowed")
        })
    }
}
