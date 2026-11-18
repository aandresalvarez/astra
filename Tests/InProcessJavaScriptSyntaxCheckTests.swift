import Testing
import Foundation
@testable import ASTRA

// Settlement verifies a delivered page's JavaScript. A process launched there
// leaves the turn's tools unverified, which reserved the workspace with
// nothing able to continue it (task 47F59E1F, a REDCap dashboard). The check
// parses in-process instead and never runs the code.

@Suite("In-process JavaScript syntax check")
struct InProcessJavaScriptSyntaxCheckTests {
    private func check(_ source: String) -> JavaScriptSyntaxCheckResult {
        TaskDeliverableVerificationService.checkJavaScriptSyntaxInProcess(source: source, sourceLabel: "index.html inline script 1")
    }

    @Test("Settlement's live check launches nothing, so the turn's tools stay stopped")
    func liveCheckLeavesSettlementToolsStopped() async {
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let results = await RuntimeSettlementExecutionScope.$current.withValue(scope) {
            [await TaskDeliverableVerificationEnvironment.live.checkJavaScriptSyntax("const a = [1, 2].map(v => v * 2);", "valid"),
             await TaskDeliverableVerificationEnvironment.live.checkJavaScriptSyntax("start(", "broken")]
        }
        #expect(results.first == .passed)
        if case .failed = results.last {} else { Issue.record("Expected a syntax failure, got \(String(describing: results.last))") }
        #expect(scope.toolsStopped)
        #expect(scope.localWorkStopped)
    }

    @Test("A classic script with valid syntax passes, including a dynamic import")
    func validClassicScriptPasses() {
        #expect(check("""
        const rows = [{ n: 1 }, { n: 2 }];
        document.getElementById("total").textContent = rows.reduce((s, r) => s + r.n, 0);
        async function load() { const m = await import("./chart.js"); return m?.draw?.(rows) ?? null; }
        class Chart { #points = []; static of(p) { return Object.assign(new Chart(), { p }); } }
        """) == .passed)
    }

    @Test("A syntax error fails with the label, line and JavaScriptCore's message")
    func syntaxErrorFails() {
        guard case .failed(let detail) = check("const a = 1;\nconst b = {;\n") else {
            Issue.record("Expected a syntax failure")
            return
        }
        #expect(detail.contains("index.html inline script 1"))
        #expect(detail.contains("line 2"))
        #expect(detail.contains("SyntaxError"))
    }

    @Test("Module syntax is reported as unchecked, never as a failure")
    func moduleSyntaxIsUnchecked() {
        for source in [#"import { start } from "./app.js"; start();"#,
                       "import * as d3 from \"https://cdn.example/d3.js\";\nd3.select(\"body\");",
                       "export const total = 3;",
                       "console.log(import.meta.url);"] {
            guard case .unavailable(let detail) = check(source) else {
                Issue.record("Expected unchecked for \(source)")
                continue
            }
            #expect(detail.contains("module syntax"))
        }
    }

    @Test("Module syntax is recognized only where a module needs it")
    func moduleSyntaxRecognition() {
        #expect(TaskDeliverableVerificationService.usesModuleSyntax("  import x from 'y'"))
        #expect(TaskDeliverableVerificationService.usesModuleSyntax("export default {}"))
        #expect(TaskDeliverableVerificationService.usesModuleSyntax("export{a}"))
        #expect(!TaskDeliverableVerificationService.usesModuleSyntax("const m = import('./m.js');"))
        #expect(!TaskDeliverableVerificationService.usesModuleSyntax("const important = exports.value;"))
    }

    @Test("The check parses without running the code", .timeLimit(.minutes(1)))
    func parsingDoesNotExecute() {
        // Evaluated, this would never return.
        #expect(check("for (;;) {}") == .passed)
    }
}
