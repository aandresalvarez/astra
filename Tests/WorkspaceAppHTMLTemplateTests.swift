import Foundation
import Testing
@testable import ASTRA

/// The deterministic interactive-HTML template library is the RESILIENT FLOOR that guarantees App
/// Studio always yields a real dynamic UI (even when model generation times out). These tests pin
/// the two invariants that make it safe to use as that floor: every template is sandbox-safe +
/// genuinely interactive + validator-valid, and intent classification routes sensibly.
@Suite("Workspace App — deterministic HTML templates (resilient floor)")
struct WorkspaceAppHTMLTemplateTests {
    private func htmlManifest(_ html: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "t", name: "T"),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: html
        )
    }

    @Test("every template is sandbox-safe, interactive, and passes the HTML-app validator")
    func everyTemplateIsValidSafeInteractive() {
        for kind in WorkspaceAppHTMLTemplate.allCases {
            let html = kind.html(title: "Demo")
            #expect(!html.isEmpty, "\(kind) is empty")
            let lower = html.lowercased()
            for banned in ["eval(", "new function", "http://", "https://", "<iframe",
                           "<script src", "<link", "@import", "fetch(", "xmlhttprequest", "websocket"] {
                #expect(!lower.contains(banned), "\(kind) contains banned token '\(banned)'")
            }
            // Genuinely interactive: a script that wires behavior.
            #expect(lower.contains("<script>"), "\(kind) has no <script>")
            #expect(lower.contains("addeventlistener") || lower.contains("onclick"), "\(kind) is not interactive")
            // The authoritative gate: it validates as an HTML app.
            #expect(WorkspaceAppManifestValidator.validate(htmlManifest(html)).isValid, "\(kind) should validate")
            // The title token is fully substituted.
            #expect(!html.contains("__APP_TITLE__"), "\(kind) left an unsubstituted title token")
        }
    }

    @Test("template classification routes intents to sensible kinds; unknown → generic")
    func templateClassification() {
        #expect(WorkspaceAppHTMLTemplate.classify("a tip calculator") == .calculator)
        #expect(WorkspaceAppHTMLTemplate.classify("a ui to manage open prs and comments") == .board)
        #expect(WorkspaceAppHTMLTemplate.classify("a dashboard of campaign metrics") == .dashboard)
        #expect(WorkspaceAppHTMLTemplate.classify("a volunteer intake form") == .form)
        #expect(WorkspaceAppHTMLTemplate.classify("a todo checklist") == .checklist)
        // Anything unrecognized still gets a real interactive UI (the generic shell).
        #expect(WorkspaceAppHTMLTemplate.classify("a random quote viewer thing") == .generic)
    }

    @Test("the title is injected and HTML-escaped (a crafted name can't inject markup)")
    func titleInjectedAndEscaped() {
        let html = WorkspaceAppHTMLTemplate.calculator.html(title: "<img src=x onerror=alert(1)>")
        #expect(!html.contains("__APP_TITLE__"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;img"))
    }

    @Test("the htmlApp fallback manifest is a real interactive UI, not a placeholder or data shell")
    func scaffoldManifestIsRealInteractiveUI() {
        let manifest = WorkspaceAppStudioBuilder.htmlAppScaffoldManifest(intent: "a ui to manage open prs and comments")
        #expect(manifest.html != nil)
        #expect(manifest.storage == nil)
        #expect(manifest.html?.lowercased().contains("<script>") == true)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }
}
