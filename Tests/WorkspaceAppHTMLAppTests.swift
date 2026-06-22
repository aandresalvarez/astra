import Foundation
import Testing
@testable import ASTRA

/// Phase 1 dynamic HTML apps: the model authors a self-contained HTML/CSS/JS UI (a calculator,
/// converter, …) that the declarative manifest vocabulary can't express. These tests pin the
/// contract that makes that safe and digest-stable: the `html` field round-trips and stays OMITTED
/// when nil, Swift owns the CSP-locked document shell, the generator parses the HTML block onto the
/// manifest, the validator enforces self-containment, and the snapshot the surface renders carries
/// the html through.
@Suite("Workspace App — dynamic HTML apps (Phase 1)")
struct WorkspaceAppHTMLAppTests {
    private func calculatorInnerHTML() -> String {
        // A real two-operand calculator that computes WITHOUT eval() — the sandbox CSP has no
        // 'unsafe-eval', so an eval-based version would silently no-op (see the eval-reject test).
        """
        <main><output id="d">0</output>
        <button onclick="digit('1')">1</button>
        <button onclick="op('+')">+</button>
        <button onclick="equals()">=</button></main>
        <style>main{display:grid}button{font-size:18px}</style>
        <script>
        var left=null, pend=null, cur='0';
        function digit(n){ cur = cur==='0' ? n : cur+n; show(cur); }
        function op(o){ left=parseFloat(cur); pend=o; cur='0'; }
        function equals(){ var r=parseFloat(cur); if(pend==='+') r=left+r; else if(pend==='-') r=left-r; else if(pend==='*') r=left*r; else if(pend==='/') r = r!==0 ? left/r : 0; cur=String(r); show(cur); pend=null; }
        function show(v){ document.getElementById('d').textContent=v; }
        </script>
        """
    }

    private func htmlManifest(html: String? = nil) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "calculator",
                name: "Calculator",
                icon: "plus.forwardslash.minus",
                description: "A simple calculator.",
                archetypes: ["HTML App"]
            ),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly),
            html: html ?? calculatorInnerHTML()
        )
    }

    // MARK: - Manifest: round-trip + digest stability

    @Test("html round-trips through Codable")
    func htmlRoundTrips() throws {
        let manifest = htmlManifest()
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WorkspaceAppManifest.self, from: data)
        #expect(decoded.html == manifest.html)
    }

    @Test("a manifest with no html OMITS the key — declarative digests stay byte-stable")
    func nilHTMLIsOmitted() throws {
        let declarative = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        #expect(declarative.html == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(declarative), encoding: .utf8) ?? ""
        #expect(!json.contains("\"html\""))
    }

    // MARK: - Document shell: Swift owns the CSP, model owns the content

    @Test("appDocument wraps the model's inner content in the locked CSP shell")
    func appDocumentIsLockedDown() {
        let inner = calculatorInnerHTML()
        let doc = WorkspaceAppWebReportHTML.appDocument(innerHTML: inner)
        // The model's content is present, wrapped in a Swift-owned document.
        #expect(doc.contains(inner))
        #expect(doc.contains("<!DOCTYPE html>"))
        // The CSP Swift enforces regardless of content.
        #expect(doc.contains("default-src 'none'"))          // no network of any kind
        #expect(doc.contains("script-src 'unsafe-inline'"))  // inline app script + onclick run
        #expect(doc.contains("style-src 'unsafe-inline'"))   // the app's own CSS
        #expect(doc.contains("base-uri 'none'"))             // can't repoint relative URLs
        #expect(doc.contains("form-action 'none'"))          // can't POST anywhere
        // The shell itself adds no external resources.
        #expect(!doc.contains("http://"))
        #expect(!doc.contains("https://"))
    }

    // MARK: - Lenient decode: a minimal model manifest that omits empty fields still decodes

    @Test("a minimal manifest that omits empty arrays/defaults decodes (no opaque keyNotFound)")
    func minimalManifestDecodesLeniently() throws {
        // The exact shape a model emits for an HTML app: metadata + html only, every no-op
        // collection omitted. The synthesized decoder would reject this with keyNotFound; the
        // lenient decoder defaults the omitted fields so generation no longer falls back to a
        // template. Metadata likewise omits icon/description/tags/archetypes.
        let json = """
        { "schemaVersion": 1,
          "app": { "id": "calculator", "name": "Calculator" },
          "permissions": { "defaultMode": "draftOnly" },
          "html": "<main>x</main>" }
        """
        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))
        #expect(manifest.requirements.isEmpty)
        #expect(manifest.sources.isEmpty)
        #expect(manifest.views.isEmpty)
        #expect(manifest.actions.isEmpty)
        #expect(manifest.automations.isEmpty)
        #expect(manifest.app.icon == "square.grid.2x2")
        #expect(manifest.app.archetypes.isEmpty)
        #expect(manifest.html == "<main>x</main>")
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("a manifest missing app id/name decodes but fails validation with a clear blocker")
    func missingIdentityBecomesValidatorBlocker() throws {
        let json = """
        { "app": { }, "html": "<main>x</main>" }
        """
        let manifest = try JSONDecoder().decode(WorkspaceAppManifest.self, from: Data(json.utf8))
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path == "/app/id" })
    }

    // MARK: - Generation: ASTRA_APP_HTML block → manifest.html

    private func structuredOutput(manifest: WorkspaceAppManifest, htmlBlock: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: (try? encoder.encode(manifest)) ?? Data(), encoding: .utf8) ?? "{}"
        var output = """
        ASTRA_APP_SUMMARY: A calculator.
        ASTRA_APP_MANIFEST
        \(json)
        END_ASTRA_APP_MANIFEST
        """
        if let htmlBlock {
            output += "\n\nASTRA_APP_HTML\n\(htmlBlock)\nEND_ASTRA_APP_HTML"
        }
        return output
    }

    @Test("applyStructuredOutput parses the ASTRA_APP_HTML block onto manifest.html")
    func structuredOutputParsesHTMLBlock() {
        // The manifest block carries metadata only (no html); the html arrives in its own block.
        let metadataOnly = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "calculator", name: "Calculator"),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        let inner = calculatorInnerHTML()
        let output = structuredOutput(manifest: metadataOnly, htmlBlock: inner)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: metadataOnly)
        #expect(result.accepted)
        #expect(result.manifest.html == inner)
        #expect(result.validationReport.isValid)
    }

    @Test("a declarative manifest output leaves html nil")
    func declarativeOutputHasNoHTML() {
        let declarative = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        let output = structuredOutput(manifest: declarative, htmlBlock: nil)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: declarative)
        #expect(result.accepted)
        #expect(result.manifest.html == nil)
    }

    @Test("a malformed HTML block (missing END) is a hard structured-output failure")
    func malformedHTMLBlockFails() {
        let metadataOnly = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "calculator", name: "Calculator"),
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: (try? encoder.encode(metadataOnly)) ?? Data(), encoding: .utf8) ?? "{}"
        let output = """
        ASTRA_APP_MANIFEST
        \(json)
        END_ASTRA_APP_MANIFEST
        ASTRA_APP_HTML
        <main>no end marker</main>
        """
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: metadataOnly)
        #expect(!result.accepted)
    }

    // MARK: - Validator: self-containment + usability skip

    @Test("a valid HTML app passes validation")
    func validHTMLAppIsValid() {
        #expect(WorkspaceAppManifestValidator.validate(htmlManifest()).isValid)
    }

    @Test("empty html is rejected")
    func emptyHTMLRejected() {
        let report = WorkspaceAppManifestValidator.validate(htmlManifest(html: "   "))
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path == "/html" })
    }

    @Test("oversized html is rejected")
    func oversizedHTMLRejected() {
        let huge = String(repeating: "x", count: 300_000)
        let report = WorkspaceAppManifestValidator.validate(htmlManifest(html: "<div>\(huge)</div>"))
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("KB limit") })
    }

    @Test("an <iframe> is rejected")
    func iframeRejected() {
        let report = WorkspaceAppManifestValidator.validate(
            htmlManifest(html: "<iframe src=\"x\"></iframe>")
        )
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("iframe") })
    }

    @Test("an external resource (src=http) is rejected")
    func externalResourceRejected() {
        let report = WorkspaceAppManifestValidator.validate(
            htmlManifest(html: "<script src=\"https://cdn.example.com/x.js\"></script><main>x</main>")
        )
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("self-contained") })
    }

    @Test("an HTML app that also declares storage/views is rejected (self-contained-UI invariant)")
    func htmlAppWithDataFeaturesRejected() {
        // Phase 1: an HTML app is self-contained UI only. Carrying storage/views (which the WebView
        // surface would never render) is a governance blind spot, so the validator blocks it.
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "rows", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        manifest.views = [WorkspaceAppViewSpec(id: "t", type: "table", title: "Rows", table: "rows")]
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("self-contained UI only") })
    }

    @Test("an HTML app using eval()/new Function is rejected (no 'unsafe-eval' in the CSP)")
    func htmlAppWithEvalRejected() {
        let evalApp = htmlManifest(html: "<button onclick=\"alert(eval('1+1'))\">go</button>")
        let report = WorkspaceAppManifestValidator.validate(evalApp)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("unsafe-eval") })
        // An identifier merely ending in 'eval' (e.g. retrieval()) is NOT a false positive.
        let okApp = htmlManifest(html: "<script>function retrieval(){return 1;} retrieval();</script><main>x</main>")
        #expect(WorkspaceAppManifestValidator.validate(okApp).isValid)
    }

    // MARK: - Surface decision precondition

    @Test("the preview snapshot carries html through to the surface")
    func snapshotCarriesHTML() {
        let manifest = htmlManifest()
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest)
        #expect(snapshot.manifest?.html == manifest.html)
    }
}
