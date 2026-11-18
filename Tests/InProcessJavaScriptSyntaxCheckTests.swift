import Testing
import Foundation
@testable import ASTRA

// Settlement verifies a delivered page's JavaScript. A process launched there
// leaves the turn's tools unverified, which reserved the workspace with
// nothing able to continue it (task 47F59E1F, a REDCap dashboard). The check
// parses in-process instead and never runs the delivered code.
//
// These tests run against the system JavaScriptCore on purpose: the module
// classification reads its diagnostics, so a change in their wording must fail
// here rather than misgrade a deliverable.

@Suite("In-process JavaScript syntax check")
struct InProcessJavaScriptSyntaxCheckTests {
    private func check(_ source: String, as kind: JavaScriptSourceKind) -> JavaScriptSyntaxCheckResult {
        TaskDeliverableVerificationService.checkJavaScriptSyntaxInProcess(
            source: source, sourceLabel: "index.html inline script 1", kind: kind)
    }

    private func isFailure(_ result: JavaScriptSyntaxCheckResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    private func isUnchecked(_ result: JavaScriptSyntaxCheckResult) -> Bool {
        if case .unavailable = result { return true }
        return false
    }

    /// Valid only in a module, in every position the old text search missed.
    private static let moduleOnlySources = [
        #"import { start } from "./app.js"; start();"#,
        "import * as d3 from \"https://cdn.example/d3.js\";\nd3.select(\"body\");",
        #"import "./side-effect.js";"#,
        #"import /* why */ { a } from "./a.js";"#,
        "import // why\n { a } from \"./a.js\";",
        "export const total = 3;",
        "const n = 1; export { n };",
        "console.log(import.meta.url);",
        #"const response = await fetch("/data.json");"#,
        "for await (const row of rows) { render(row); }",
        "const rows = await load();\nexport { rows };"
    ]

    /// Broken in a module and in a script alike, including text that mentions
    /// module syntax and bodies that would close a text wrapper early.
    private static let brokenSources = [
        #"const s = "import.meta"; const broken = ;"#,
        "// export { x }\nconst b = {;",
        "const note = `import x from 'y'`;\nstart(",
        "function f() { await load(); }",
        "await a();\nconst b = {;",
        "doThing(); })(); (function () { other();",
        "const a = 1; } + function () {"
    ]

    @Test("Settlement's live check launches nothing, so the turn's tools stay stopped")
    func liveCheckLeavesSettlementToolsStopped() async {
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let live = TaskDeliverableVerificationEnvironment.live
        let results = await RuntimeSettlementExecutionScope.$current.withValue(scope) {
            [await live.checkJavaScriptSyntax("const a = [1, 2].map(v => v * 2);", "valid", .classicScript),
             await live.checkJavaScriptSyntax("start(", "broken", .classicScript),
             await live.checkJavaScriptSyntax("const r = await load();", "module", .unknown)]
        }
        #expect(results[0] == .passed)
        #expect(isFailure(results[1]))
        #expect(isUnchecked(results[2]))
        #expect(scope.toolsStopped)
        #expect(scope.localWorkStopped)
    }

    @Test("A classic script with valid syntax passes, including a dynamic import")
    func validClassicScriptPasses() {
        let source = """
        const rows = [{ n: 1 }, { n: 2 }];
        document.getElementById("total").textContent = rows.reduce((s, r) => s + r.n, 0);
        async function load() { const m = await import("./chart.js"); return m?.draw?.(rows) ?? null; }
        class Chart { #points = []; static of(p) { return Object.assign(new Chart(), { p }); } }
        """
        for kind in [JavaScriptSourceKind.classicScript, .module, .unknown] {
            #expect(check(source, as: kind) == .passed)
        }
    }

    @Test("A syntax error fails with the label, line and JavaScriptCore's message")
    func syntaxErrorFails() {
        guard case .failed(let detail) = check("const a = 1;\nconst b = {;\n", as: .classicScript) else {
            Issue.record("Expected a syntax failure")
            return
        }
        #expect(detail.contains("index.html inline script 1"))
        #expect(detail.contains("line 2"))
        #expect(detail.contains("SyntaxError"))
    }

    @Test("Module syntax in a module or a file of unknown kind is unchecked, wherever it appears",
          arguments: moduleOnlySources)
    func moduleSyntaxIsUnchecked(source: String) {
        for kind in [JavaScriptSourceKind.module, .unknown] {
            guard case .unavailable(let detail) = check(source, as: kind) else {
                Issue.record("Expected unchecked for \(kind): \(source)")
                continue
            }
            #expect(detail.contains("module"))
            #expect(detail.contains("index.html inline script 1"))
        }
    }

    @Test("A real syntax error still fails when the text mentions module syntax or closes a wrapper",
          arguments: brokenSources)
    func realErrorStaysAFailure(source: String) {
        for kind in [JavaScriptSourceKind.classicScript, .module, .unknown] {
            #expect(isFailure(check(source, as: kind)), "\(kind): \(source)")
        }
    }

    @Test("Module syntax in a classic HTML script fails, as it does in a browser",
          arguments: moduleOnlySources)
    func classicScriptRejectsModuleSyntax(source: String) {
        #expect(isFailure(check(source, as: .classicScript)), "\(source)")
    }

    @Test("A top-level return, legal in a CommonJS file, is unchecked rather than failed")
    func commonJSReturnIsUnchecked() {
        #expect(isUnchecked(check("if (!ready) return;\nmodule.exports = 1;", as: .unknown)))
    }

    @Test("Neither parse runs the code", .timeLimit(.minutes(1)))
    func parsingDoesNotExecute() {
        // Evaluated, either of these would never return.
        #expect(check("for (;;) {}", as: .classicScript) == .passed)
        #expect(isUnchecked(check("await ready; for (;;) {}", as: .unknown)))
    }
}
