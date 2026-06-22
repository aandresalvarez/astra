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

    @Test("the data-backed HTML template is sandbox-safe, uses the astra bridge, and validates")
    func dataTemplateUsesBridgeAndValidates() {
        let cols = [
            WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
            WorkspaceAppStorageColumn(name: "title", type: "text")
        ]
        let html = WorkspaceAppDataHTMLTemplate.html(title: "Notes", table: "notes", columns: cols, primaryKey: "id")
        // Uses the bridge, all placeholders substituted, sandbox-safe.
        #expect(html.contains("astra.query") && html.contains("astra.insert") && html.contains("astra.update"))
        for token in ["__APP_TITLE__", "__TABLE__", "__COLUMNS__", "__PRIMARY_KEY__"] { #expect(!html.contains(token)) }
        #expect(html.contains("\"notes\""))   // table injected as a JS string
        #expect(html.contains("\"title\""))    // editable (non-pk) column injected into COLUMNS
        let low = html.lowercased()
        for banned in ["eval(", "<iframe", "http://", "https://", "crypto.randomuuid", "fetch("] { #expect(!low.contains(banned)) }
        // Validates as a data-backed HTML app.
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "notes", name: "Notes"),
            storage: WorkspaceAppStorageSchema(tables: [WorkspaceAppStorageTable(name: "notes", columns: cols)]),
            actions: [WorkspaceAppActionSpec(id: "q", type: "appStorage.query", table: "notes")],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: html
        )
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("the data template is injection-safe by construction (crafted table/pk can't break out)")
    func dataTemplateIsInjectionSafe() {
        // Today's callers pass hardcoded "records"/"id", but the helper must be safe for any
        // identifier: a table/pk containing a quote or a `</script>` must stay inside its JS string
        // literal and must NOT close the inline <script> element via the HTML parser.
        let nasty = "evil\"; window.x=1; var y=\"</script><img src=x onerror=alert(1)>"
        let cols = [
            WorkspaceAppStorageColumn(name: nasty, type: "text", primaryKey: true, required: true),
            WorkspaceAppStorageColumn(name: "ok", type: "text")
        ]
        let html = WorkspaceAppDataHTMLTemplate.html(title: "T", table: nasty, columns: cols, primaryKey: nasty)
        // The payload's `</script>` and `<img>` never appear unescaped (they would close the script
        // element / inject a tag); every `<` is neutralized to its < escape, and the quote is
        // JSON-escaped (`evil\"`) so it stays inside the JS string literal rather than breaking out.
        #expect(!html.contains("</script><img"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("\\u003c"))      // the payload's `<` was neutralized
        #expect(html.contains("evil\\\""))     // the payload's `"` was JSON-escaped
        // Defense in depth: a published data app can never carry such an identifier in the first place
        // — the manifest validator independently rejects out-of-charset table/column names, so this
        // string can't reach the template through a real manifest.
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "t", name: "T"),
            storage: WorkspaceAppStorageSchema(tables: [WorkspaceAppStorageTable(name: nasty, columns: cols)]),
            actions: [WorkspaceAppActionSpec(id: "q", type: "appStorage.query", table: nasty)],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: html
        )
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("Table name may contain only") })
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
