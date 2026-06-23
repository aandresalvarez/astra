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

    // MARK: - Decode failures name the offending field (so the repair loop can self-correct)

    private func manifestOutput(_ json: String) -> String {
        "ASTRA_APP_MANIFEST\n\(json)\nEND_ASTRA_APP_MANIFEST"
    }

    private static let preserved = WorkspaceAppManifest(
        app: WorkspaceAppManifestMetadata(id: "keep", name: "Keep")
    )

    @Test("a manifest action missing 'type' fails with a path-named message, not an opaque one")
    func decodeMissingActionTypeNamesField() {
        // The exact shape behind the user's "the data couldn't be read because it is missing." —
        // a model re-emitted the manifest but dropped a structural field on a new action.
        let output = manifestOutput(#"{"app":{"id":"x","name":"X"},"actions":[{"id":"del"}]}"#)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: Self.preserved)
        #expect(!result.accepted)
        let message = result.validationReport.issues.first?.message ?? ""
        #expect(message.contains("type"))           // names the missing field
        #expect(message.contains("actions[0]"))      // and where it is
        // The whole point: NOT the opaque Foundation string that starved the repair loop.
        #expect(!message.contains("couldn't be read"))
        // The base manifest is preserved on failure.
        #expect(result.manifest == Self.preserved)
    }

    @Test("a null required field decodes to a 'is null' message, not 'missing'")
    func decodeNullValueNamesField() {
        let output = manifestOutput(#"{"app":{"id":"x","name":"X"},"actions":[{"id":"d","type":null}]}"#)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: Self.preserved)
        #expect(!result.accepted)
        let message = result.validationReport.issues.first?.message ?? ""
        #expect(message.contains("actions[0].type"))
        #expect(message.contains("null"))
    }

    @Test("a wrong-typed field decodes to a 'wrong type' message")
    func decodeTypeMismatchNamesField() {
        let output = manifestOutput(#"{"app":{"id":"x","name":"X"},"schemaVersion":"two"}"#)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: Self.preserved)
        #expect(!result.accepted)
        let message = result.validationReport.issues.first?.message ?? ""
        #expect(message.contains("schemaVersion"))
        #expect(message.contains("wrong type"))
    }

    @Test("an omitted app block decodes leniently → the validator's clear identity blocker")
    func omittedAppBlockRoutesToValidator() {
        // Lenient top-level decode: a missing `app` is no longer an opaque decode failure; it
        // decodes to empty identity and the validator reports the actionable, dedicated blocker.
        let output = manifestOutput(#"{"actions":[]}"#)
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: Self.preserved)
        #expect(!result.accepted)
        #expect(result.validationReport.blockers.contains { $0.path == "/app/name" })
        // It reached the validator, not the decode-failure path.
        #expect(!(result.validationReport.issues.first?.message.contains("decode") ?? false))
    }

    // MARK: - Progressive refinement: a patch + a fresh HTML block

    @Test("a refinement patch + a fresh HTML block updates the manifest AND swaps the UI")
    func patchWithHTMLBlockUpdatesBoth() {
        let base = htmlManifest()
        let newHTML = "<main><h1>Edited</h1></main>"
        let output = """
        ASTRA_APP_SUMMARY: Renamed and rebuilt the UI.
        ASTRA_APP_PATCH
        [{"op":"replace","path":"/app/name","value":"Edited Name"}]
        END_ASTRA_APP_PATCH
        ASTRA_APP_HTML
        \(newHTML)
        END_ASTRA_APP_HTML
        """
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: base)
        #expect(result.accepted)
        #expect(result.manifest.app.name == "Edited Name")   // manifest delta applied
        #expect(result.manifest.html == newHTML)             // UI body replaced
    }

    @Test("an empty patch + a fresh HTML block swaps ONLY the UI")
    func emptyPatchSwapsHTMLOnly() {
        let base = htmlManifest()
        let newHTML = "<main><h1>UI only</h1></main>"
        let output = """
        ASTRA_APP_PATCH
        []
        END_ASTRA_APP_PATCH
        ASTRA_APP_HTML
        \(newHTML)
        END_ASTRA_APP_HTML
        """
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: base)
        #expect(result.accepted)
        #expect(result.manifest.html == newHTML)
        #expect(result.manifest.app.name == base.app.name)   // manifest untouched
    }

    @Test("a manifest-only patch (no HTML block) keeps the existing UI")
    func patchOnlyKeepsHTML() {
        let base = htmlManifest()
        let output = """
        ASTRA_APP_PATCH
        [{"op":"replace","path":"/app/name","value":"Renamed"}]
        END_ASTRA_APP_PATCH
        """
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: base)
        #expect(result.accepted)
        #expect(result.manifest.app.name == "Renamed")
        #expect(result.manifest.html == base.html)           // UI preserved across a data-only edit
    }

    // MARK: - Progressive HTML editing: surgical ASTRA_APP_HTML_EDIT (the delta channel for the UI body)

    @Test("applyHTMLEdits replaces a unique anchor and leaves the rest byte-identical")
    func htmlEditsReplaceUniqueAnchor() {
        let html = "<main><button onclick=\"a()\">A</button><button onclick=\"b()\">B</button></main>"
        let edit = WorkspaceAppStudioHTMLEdit(find: "onclick=\"a()\">A", replace: "onclick=\"a2()\">A2")
        guard case let .applied(out) = WorkspaceAppStudioBuilder.applyHTMLEdits([edit], to: html) else {
            Issue.record("expected the edit to apply"); return
        }
        #expect(out == "<main><button onclick=\"a2()\">A2</button><button onclick=\"b()\">B</button></main>")
    }

    @Test("a sequence of edits compounds (a later find sees an earlier replace)")
    func htmlEditsCompound() {
        let html = "<p>one</p>"
        let edits = [
            WorkspaceAppStudioHTMLEdit(find: "one", replace: "two"),
            WorkspaceAppStudioHTMLEdit(find: "<p>two</p>", replace: "<p>two</p><p>three</p>")
        ]
        guard case let .applied(out) = WorkspaceAppStudioBuilder.applyHTMLEdits(edits, to: html) else {
            Issue.record("expected the edits to apply"); return
        }
        #expect(out == "<p>two</p><p>three</p>")
    }

    @Test("an anchor that does not appear is rejected, not applied to the wrong place")
    func htmlEditAnchorNotFound() {
        let result = WorkspaceAppStudioBuilder.applyHTMLEdits(
            [WorkspaceAppStudioHTMLEdit(find: "no-such-text", replace: "x")],
            to: "<main>hello</main>"
        )
        guard case let .failure(message) = result else { Issue.record("expected failure"); return }
        #expect(message.contains("anchor not found"))
    }

    @Test("an ambiguous anchor (matches more than once) is rejected")
    func htmlEditAnchorAmbiguous() {
        let result = WorkspaceAppStudioBuilder.applyHTMLEdits(
            [WorkspaceAppStudioHTMLEdit(find: "<li>", replace: "<li class=x>")],
            to: "<ul><li>a</li><li>b</li></ul>"
        )
        guard case let .failure(message) = result else { Issue.record("expected failure"); return }
        #expect(message.contains("ambiguous"))
    }

    @Test("a no-op edit (find == replace) is rejected so 'fix it' can't change nothing")
    func htmlEditNoOpRejected() {
        let result = WorkspaceAppStudioBuilder.applyHTMLEdits(
            [WorkspaceAppStudioHTMLEdit(find: "hello", replace: "hello")],
            to: "<main>hello</main>"
        )
        guard case let .failure(message) = result else { Issue.record("expected failure"); return }
        #expect(message.contains("unchanged"))
    }

    private func htmlEditOutput(_ editsJSON: String, patchJSON: String? = nil) -> String {
        var output = "ASTRA_APP_SUMMARY: Surgical UI edit.\n"
        if let patchJSON {
            output += "ASTRA_APP_PATCH\n\(patchJSON)\nEND_ASTRA_APP_PATCH\n"
        }
        output += "ASTRA_APP_HTML_EDIT\n\(editsJSON)\nEND_ASTRA_APP_HTML_EDIT"
        return output
    }

    @Test("ASTRA_APP_HTML_EDIT alone patches the UI body in place, manifest untouched")
    func structuredOutputAppliesHTMLEdit() {
        let base = htmlManifest(html: "<main><button onclick=\"go()\">Go</button></main>")
        let edits = #"[{"find":"onclick=\"go()\">Go","replace":"onclick=\"stop()\">Stop"}]"#
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(htmlEditOutput(edits), to: base)
        #expect(result.accepted)
        #expect(result.manifest.html == "<main><button onclick=\"stop()\">Stop</button></main>")
        #expect(result.manifest.app.name == base.app.name)   // manifest unchanged
    }

    @Test("ASTRA_APP_HTML_EDIT + a manifest patch apply together")
    func structuredOutputAppliesHTMLEditAndPatch() {
        let base = htmlManifest(html: "<main><h1>Old</h1></main>")
        let edits = #"[{"find":"<h1>Old</h1>","replace":"<h1>New</h1>"}]"#
        let patch = #"[{"op":"replace","path":"/app/name","value":"Renamed"}]"#
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(htmlEditOutput(edits, patchJSON: patch), to: base)
        #expect(result.accepted)
        #expect(result.manifest.html == "<main><h1>New</h1></main>")
        #expect(result.manifest.app.name == "Renamed")
    }

    @Test("a failed anchor routes to a non-accepted result with a repair-actionable message")
    func structuredOutputHTMLEditFailureSurfaces() {
        let base = htmlManifest(html: "<main>hello</main>")
        let edits = #"[{"find":"absent-snippet","replace":"x"}]"#
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(htmlEditOutput(edits), to: base)
        #expect(!result.accepted)
        #expect(result.validationReport.issues.first?.message.contains("anchor not found") == true)
        #expect(result.manifest.html == base.html)   // original preserved on failure
    }

    @Test("ASTRA_APP_HTML_EDIT on a declarative (non-HTML) app is rejected, app preserved")
    func structuredOutputHTMLEditOnNonHTMLApp() {
        let declarative = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "groceries")
        let edits = #"[{"find":"x","replace":"y"}]"#
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(htmlEditOutput(edits), to: declarative)
        #expect(!result.accepted)
        #expect(result.validationReport.issues.first?.message.contains("no HTML body") == true)
    }

    @Test("ASTRA_APP_HTML_EDIT plus a full ASTRA_APP_HTML block is rejected (ambiguous intent)")
    func structuredOutputHTMLEditExclusiveWithFullHTML() {
        let base = htmlManifest(html: "<main>x</main>")
        let output = """
        ASTRA_APP_HTML_EDIT
        [{"find":"x","replace":"y"}]
        END_ASTRA_APP_HTML_EDIT
        ASTRA_APP_HTML
        <main>full replacement</main>
        END_ASTRA_APP_HTML
        """
        let result = WorkspaceAppStudioBuilder.applyStructuredOutput(output, to: base)
        #expect(!result.accepted)
        #expect(result.manifest.html == base.html)
    }

    @Test("a surgical edit that injects sandbox-forbidden content is rejected, original preserved")
    func htmlEditCannotEscapeTheSandbox() {
        // The edited HTML still flows through the HTML-app validator — a unique, well-formed anchor
        // can't smuggle an iframe / external script / network call past the CSP rules.
        let base = htmlManifest(html: "<main><p>safe</p></main>")
        for injected in ["<iframe src=\"x\"></iframe>", "<script src=\"https://evil/x.js\"></script>", "<p onclick=\"fetch('https://evil')\">x</p>"] {
            let edits = "[{\"find\":\"<p>safe</p>\",\"replace\":\"\(injected.replacingOccurrences(of: "\"", with: "\\\""))\"}]"
            let result = WorkspaceAppStudioBuilder.applyStructuredOutput(htmlEditOutput(edits), to: base)
            #expect(!result.accepted, "injection should be rejected: \(injected)")
            #expect(result.manifest.html == base.html)   // original preserved
        }
    }

    @Test("an over-cap edit batch is rejected before it can burn CPU")
    func htmlEditBatchCapEnforced() {
        let edit = WorkspaceAppStudioHTMLEdit(find: "x", replace: "y")
        let tooMany = Array(repeating: edit, count: WorkspaceAppStudioBuilder.maxHTMLEdits + 1)
        guard case let .failure(message) = WorkspaceAppStudioBuilder.applyHTMLEdits(tooMany, to: "<main>x</main>") else {
            Issue.record("expected the over-cap batch to be rejected"); return
        }
        #expect(message.contains("at most"))
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

    @Test("an HTML app MAY declare its own storage + appStorage actions (Phase 2 data-bridge allowlist)")
    func htmlAppWithOwnStorageIsValid() {
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "rows", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "title", type: "text")
            ])
        ])
        manifest.actions = [
            WorkspaceAppActionSpec(id: "q", type: "appStorage.query", table: "rows"),
            WorkspaceAppActionSpec(id: "i", type: "appStorage.insert", table: "rows")
        ]
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("an HTML app declaring connectors / native views / a connector or url.open action is rejected")
    func htmlAppWithForbiddenFeaturesRejected() {
        // Native views: the HTML renders the UI, so declaring widgets is a governance blind spot.
        var withViews = htmlManifest()
        withViews.views = [WorkspaceAppViewSpec(id: "t", type: "table", title: "Rows", table: "rows")]
        #expect(!WorkspaceAppManifestValidator.validate(withViews).isValid)

        // Connectors: an HTML app is local-only — no networked surface.
        var withConnector = htmlManifest()
        withConnector.requirements = [
            WorkspaceAppRequirement(id: "r", contract: "tabularQuery.read", operations: ["runReadOnlyQuery"], optional: true, reason: "x")
        ]
        #expect(!WorkspaceAppManifestValidator.validate(withConnector).isValid)

        // A connector WRITE action (networked) is not allowed — only local workflow actions are.
        var withCapability = htmlManifest()
        withCapability.actions = [WorkspaceAppActionSpec(id: "c", type: "capability.write", table: "rows")]
        #expect(!WorkspaceAppManifestValidator.validate(withCapability).isValid)

        // url.open (arbitrary navigation) is excluded from the workflow allowlist.
        var withURL = htmlManifest()
        withURL.actions = [WorkspaceAppActionSpec(id: "u", type: "url.open")]
        #expect(!WorkspaceAppManifestValidator.validate(withURL).isValid)
    }

    @Test("Phase 5 gating: an HTML pipeline that exports WITHOUT a preceding human gate is rejected")
    func htmlPipelineExportWithoutGateRejected() {
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        manifest.permissions = WorkspaceAppPermissions(reads: ["appStorage.items"], writes: ["appStorage.items"], defaultMode: .approvalRequired)
        manifest.actions = [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "export", type: "artifact.export", table: "items", exportFormat: "csv"),
            // Ungated: export runs with no preceding gate.humanApproval → a JS trigger writes ungated.
            WorkspaceAppActionSpec(id: "run", type: "pipeline.run", steps: ["list", "export"])
        ]
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("without a preceding gate.humanApproval") })

        // Adding the gate before the export makes it valid.
        manifest.actions = [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "approve", type: "gate.humanApproval", approvalPrompt: "ok?", approvalDecisions: ["approve", "reject"]),
            WorkspaceAppActionSpec(id: "export", type: "artifact.export", table: "items", exportFormat: "csv"),
            WorkspaceAppActionSpec(id: "run", type: "pipeline.run", steps: ["list", "approve", "export"])
        ]
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("Phase 5 gating: branch/fan-out primitives can't be declared (no indirect ungated export)")
    func htmlAppBranchAndFanOutRejected() {
        // gate.branch would let `pipeline.run -> gate.branch -> artifact.export` reach an ungated
        // export past the flat gate check; it's excluded from the HTML action vocabulary entirely.
        var withBranch = htmlManifest()
        withBranch.actions = [WorkspaceAppActionSpec(id: "b", type: "gate.branch")]
        #expect(!WorkspaceAppManifestValidator.validate(withBranch).isValid)
        // task.fanOut (parallel agent children) is likewise excluded.
        var withFanOut = htmlManifest()
        withFanOut.actions = [WorkspaceAppActionSpec(id: "f", type: "task.fanOut")]
        #expect(!WorkspaceAppManifestValidator.validate(withFanOut).isValid)
    }

    @Test("Phase 5 gating: a pipeline may not nest another pipeline as a step (flat-only)")
    func htmlAppNestedPipelineStepRejected() {
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        manifest.permissions = WorkspaceAppPermissions(reads: ["appStorage.items"], writes: ["appStorage.items"], defaultMode: .draftOnly)
        manifest.actions = [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "inner", type: "pipeline.run", steps: ["list"]),
            WorkspaceAppActionSpec(id: "outer", type: "pipeline.run", steps: ["inner"])
        ]
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("may not nest another") })
    }

    @Test("Phase 5 gating: an HTML loop running an agent task / export is rejected (inline, no gate)")
    func htmlLoopWithExternalEffectRejected() {
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        manifest.permissions = WorkspaceAppPermissions(reads: ["appStorage.items"], writes: ["appStorage.items"], defaultMode: .preApproved)
        manifest.actions = [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", table: "items"),
            WorkspaceAppActionSpec(id: "spawn", type: "task.createAndRun", taskTitle: "x", taskGoal: "y"),
            WorkspaceAppActionSpec(
                id: "loop", type: "loop.run",
                gateField: "status", gateOperator: "equals", gateValue: .text("done"),
                steps: ["list", "spawn"],
                maxIterations: 5, timeoutSeconds: 30, delaySeconds: 0
            )
        ]
        let report = WorkspaceAppManifestValidator.validate(manifest)
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.message.contains("must not run an external-effect step") })
    }

    @Test("Phase 5: an HTML app MAY declare governed workflow actions (task/gate/pipeline/export/notify)")
    func htmlAppWithWorkflowActionsIsValid() {
        var manifest = htmlManifest()
        manifest.storage = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "review_items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "title", type: "text")
            ])
        ])
        manifest.permissions = WorkspaceAppPermissions(
            reads: ["appStorage.review_items"], writes: ["appStorage.review_items"], defaultMode: .approvalRequired
        )
        manifest.actions = [
            WorkspaceAppActionSpec(id: "q", type: "appStorage.query", table: "review_items"),
            WorkspaceAppActionSpec(id: "i", type: "appStorage.insert", table: "review_items"),
            WorkspaceAppActionSpec(id: "g", type: "gate.humanApproval", approvalPrompt: "ok?", approvalDecisions: ["approve", "reject"]),
            WorkspaceAppActionSpec(id: "x", type: "artifact.export", table: "review_items", exportFormat: "csv"),
            WorkspaceAppActionSpec(id: "n", type: "notification.show", notificationTitle: "Done"),
            WorkspaceAppActionSpec(id: "p", type: "pipeline.run", steps: ["q", "g", "x"])
        ]
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("network APIs (fetch/XHR/WebSocket/EventSource/sendBeacon/@import/import()) are rejected")
    func networkAPIsRejected() {
        // The CSP blocks the actual egress at runtime, but the validator must also reject these so a
        // non-self-contained app can't pass review — a data app reaches its own storage through the
        // astra.* bridge, never the network.
        let cases: [String] = [
            "<script>fetch('https://x')</script><main>x</main>",
            "<script>new XMLHttpRequest()</script><main>x</main>",
            "<script>new WebSocket('wss://x')</script><main>x</main>",
            "<script>new EventSource('/x')</script><main>x</main>",
            "<script>navigator.sendBeacon('/x')</script><main>x</main>",
            "<style>@import url('x.css')</style><main>x</main>",
            "<script>import('./x.js')</script><main>x</main>"
        ]
        for html in cases {
            let report = WorkspaceAppManifestValidator.validate(htmlManifest(html: html))
            #expect(!report.isValid, "should reject: \(html)")
        }
        // A standalone-call check, so 'prefetch(' / a property named 'eventsourceUrl' don't false-positive.
        let ok = htmlManifest(html: "<script>function prefetch(){return 1;} prefetch();</script><main>x</main>")
        #expect(WorkspaceAppManifestValidator.validate(ok).isValid)
    }

    @Test("a <link> or a <script src> (even data:) is rejected — inline-only")
    func externalScriptAndLinkRejected() {
        let link = WorkspaceAppManifestValidator.validate(
            htmlManifest(html: "<link rel=\"stylesheet\" href=\"x.css\"><main>x</main>")
        )
        #expect(!link.isValid)
        // data: bypasses the http-only src check but is still an external/non-inline script.
        let dataScript = WorkspaceAppManifestValidator.validate(
            htmlManifest(html: "<script src=\"data:text/javascript,alert(1)\"></script><main>x</main>")
        )
        #expect(!dataScript.isValid)
        #expect(dataScript.blockers.contains { $0.message.contains("self-contained") })
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
