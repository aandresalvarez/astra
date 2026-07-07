import Foundation
import Testing
@testable import ASTRA

/// The `chartInteractive` renderer is the ONLY one that runs JavaScript. These tests pin the
/// sandbox invariants: data can't break out of the script block, the document runs only
/// Swift-authored inline script with no network/external sources, JS is enabled for ONLY this
/// renderer, and the manifest path stays validator-gated.
@Suite("Workspace App Interactive Chart (sandboxed JS)")
struct WorkspaceAppInteractiveChartTests {
    private func baseWithTable() -> WorkspaceAppManifest {
        WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
    }

    private func surface(for manifest: WorkspaceAppManifest) -> WorkspaceAppNativeSurfacePresentation {
        let snap = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest)
        return WorkspaceAppNativeSurfaceBuilder.presentation(manifest: snap.manifest, storageTables: snap.storageTables)
    }

    // MARK: - Data-island XSS safety

    @Test("a malicious cell value cannot break out of the JSON script block")
    func dataIslandNeutralizesScriptBreakout() {
        let bars = [WorkspaceAppChartPresentation.Bar(
            label: "</script><script>alert(1)</script>", value: 3, displayValue: "3", fraction: 1
        )]
        let html = WorkspaceAppWebReportHTML.interactiveChartHTML(title: "Risky", bars: bars)
        // The injected </script> must be escaped to its < form — never appear raw.
        #expect(!html.contains("<script>alert(1)"))
        #expect(!html.contains("</script><script>"))
        #expect(html.contains("\\u003c"))
    }

    @Test("the malicious title is HTML-escaped in the heading")
    func titleIsEscaped() {
        let html = WorkspaceAppWebReportHTML.interactiveChartHTML(
            title: "<img src=x onerror=alert(1)>", bars: []
        )
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;img"))
    }

    // MARK: - Locked-down document

    @Test("interactive document runs only inline script, blocks network, has no external refs")
    func interactiveDocumentIsLockedDown() {
        let bars = [WorkspaceAppChartPresentation.Bar(label: "Open", value: 2, displayValue: "2", fraction: 1)]
        let html = WorkspaceAppWebReportHTML.interactiveChartHTML(title: "Chart", bars: bars)
        #expect(html.contains("default-src 'none'"))          // no network of any kind
        #expect(html.contains("script-src 'unsafe-inline'"))  // only our inline script may run
        #expect(html.contains("base-uri 'none'"))             // can't repoint relative URLs
        #expect(html.contains("form-action 'none'"))          // can't POST data anywhere
        #expect(!html.contains("http://"))                    // no external endpoints
        #expect(!html.contains("https://"))
        #expect(!html.contains("src=\""))                     // no external <script src>/<img src>
        #expect(!html.lowercased().contains(".innerhtml"))    // vetted script writes textContent only
        #expect(!html.lowercased().contains("eval("))
        #expect(!html.lowercased().contains("fetch("))
    }

    // MARK: - JS scoped to exactly one renderer

    @Test("only chartInteractive opts into JavaScript; static renderers stay JS-off")
    func javaScriptIsScopedToInteractiveRenderer() {
        let interactive = surface(for: WorkspaceAppStudioRefinement.addInteractiveChart.apply(to: baseWithTable()))
        #expect(interactive.webReports.contains { $0.allowsJavaScript })

        let rich = surface(for: WorkspaceAppStudioRefinement.addRichReport.apply(to: baseWithTable()))
        #expect(!rich.webReports.isEmpty)
        #expect(rich.webReports.allSatisfy { !$0.allowsJavaScript })
    }

    // MARK: - Bridge + manifest gating

    @Test("the renderer policy allow-list includes the interactive renderer")
    func bridgeAllowsInteractiveRenderer() {
        #expect(WorkspaceAppWebRendererPolicy.allowedRenderers.contains("chartInteractive"))
        #expect(WorkspaceAppWebRendererPolicy.allowedRenderers.contains("htmlReport"))
    }

    @Test("addInteractiveChart adds a validated chartInteractive widget, then is unavailable")
    func refinementAddsValidatedInteractiveChart() {
        let base = baseWithTable()
        #expect(WorkspaceAppStudioRefinement.addInteractiveChart.isAvailable(for: base))

        let updated = WorkspaceAppStudioRefinement.addInteractiveChart.apply(to: base)
        #expect(updated.views.flatMap(\.widgets).contains { $0.webRenderer == "chartInteractive" })
        #expect(WorkspaceAppManifestValidator.validate(updated).isValid)
        #expect(!WorkspaceAppStudioRefinement.addInteractiveChart.isAvailable(for: updated))
    }
}
