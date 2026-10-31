import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Pending diagnostic P2 regressions")
struct PendingP2RegressionTests {
    @Test("Authenticated gh outside a repository is context, not an authentication failure")
    func ghWithoutRepositoryIsNotAuthFailure() {
        let report = LogDiagnosticsService.makeReport(entries: [LogEntry(level: .warning, category: "Worker",
            message: "local_tool.tested command=gh result=authenticated_no_repository source=task_preflight")])
        #expect(report.issues.isEmpty)
        #expect(report.notices.count == 1)
    }

    @Test("A multi-second Files delay is actionable, not a resolved notice")
    func slowFilesIsActionable() {
        let report = LogDiagnosticsService.makeReport(entries: [LogEntry(level: .warning, category: "Performance",
            message: "event=files_shelf_to_first_results duration_ms=5920 trace_id=files-slow")])
        #expect(report.issues.contains { $0.signal.contains("files_shelf_to_first_results") })
        #expect(!report.notices.contains { $0.signal.contains("files_shelf_to_first_results") })
    }

    @Test("Copilot exiting without a single byte has an actionable empty-start diagnostic")
    func completelySilentCopilotFailure() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(runtime: .copilotCLI, model: "claude-opus-5.5",
            exitCode: 1, rawError: "", providerVersion: "1.0.98", stream: AgentRuntimeStreamTelemetry().snapshot())
        #expect(diagnostic.category == .noVisibleOutput)
        #expect(diagnostic.userMessage.contains("copilot"))
        #expect(diagnostic.redactedSummary.contains("1.0.98"))
    }

    @Test("Antigravity titles explicitly select the model on the launch command")
    func antigravityTitleBindsModel() async throws {
        let root = try ProviderCoordinationFixture().data
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agy")
        try """
        #!/bin/sh
        if [ "$1" = "--help" ]; then printf '%s\\n' '--model --output-format'; exit 0; fi
        selected=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--model' ]; then shift; selected="$1"; fi
          shift
        done
        if [ -z "$selected" ]; then echo 'plan model not specified; you must specify a valid model' >&2; exit 3; fi
        echo 'Review attached agreement'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath(executable.path, for: .antigravityCLI)
        settings.setHomeDirectory(root.appendingPathComponent("provider-home").path, for: .antigravityCLI)
        let title = await SpecEngine.generateTitle(goal: "Review the attached agreement", workspacePath: root.path,
            utilityRuntime: AgentUtilityRuntimeConfiguration(runtime: .antigravityCLI, model: "gemini-3.8-flash-high", providerSettings: settings))
        #expect(title == "Review attached agreement")
    }
    @Test("A provider configuration failure stops title fallback and the remaining batch")
    func configurationFailureIsNotRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-title-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let counter = root.appendingPathComponent("attempts.txt")
        try """
        #!/bin/sh
        printf x >> '\(counter.path)'
        echo 'Authentication failed: login required' >&2
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let outcome = await TaskTitleGenerationService.generate(goal: "Test the title", workspacePath: root.path,
            configuration: .claude(path: executable.path, model: "different-from-default"))
        #expect(outcome.title == nil)
        #expect(outcome.shouldStopBatch)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "x")
    }

    @Test("Recent Copilot error logs explain an empty start; stale records and secrets stay out")
    func copilotLogEvidenceIsBoundedAndScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-copilot-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.log")
        try "[ERROR] STALE_FAILURE".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        let start = Date().addingTimeInterval(-1)
        try "[INFO] unrelated user content\n[ERROR] authentication failed OPENAI_API_KEY=sk-secret-fixture"
            .write(to: root.appendingPathComponent("current.log"), atomically: true, encoding: .utf8)
        let evidence = try #require(CopilotStartupEvidence.read(directory: root.path, since: start))
        #expect(evidence.contains("authentication failed"))
        #expect(!evidence.contains("STALE_FAILURE"))
        #expect(!evidence.contains("sk-secret-fixture"))
        #expect(!evidence.contains("unrelated user content"))
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(runtime: .copilotCLI, model: "gpt-5",
            exitCode: 1, rawError: "", providerVersion: "1.0.98", stream: nil, startupEvidence: evidence)
        #expect(diagnostic.category == .authenticationFailed)
        #expect(diagnostic.summarySource == .providerLog)
    }

    @Test("Context budget truncation closes the untrusted input before later instructions")
    func truncatedUntrustedBlockIsClosed() {
        let data = PromptUntrustedDataBlock.render(title: "Input", marker: "ASTRA_TASK_INPUT_CONTENT",
            content: String(repeating: "Document text. ", count: 2_000))
        let limited = PromptUntrustedDataBlock.boundedPrefix(data, maxCharacters: 500)
        #expect(limited.count <= 500)
        #expect(limited.ranges(of: "ASTRA_TASK_INPUT_CONTENT_BEGIN").count == 1)
        #expect(limited.ranges(of: "ASTRA_TASK_INPUT_CONTENT_END").count == 1)
        #expect(limited.hasSuffix("ASTRA_TASK_INPUT_CONTENT_END"))
    }

    @Test("Concurrent Copilot starts read only their own execution's errors")
    func copilotEvidenceIsRunScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-copilot-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let own = try #require(CopilotStartupEvidence.directory(taskFolder: root.path, runID: UUID()))
        let other = try #require(CopilotStartupEvidence.directory(taskFolder: root.path, runID: UUID()))
        try FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-1)
        try "[ERROR] OTHER_EXECUTION_FAILURE".write(toFile: other + "/process.log", atomically: true, encoding: .utf8)
        #expect(CopilotStartupEvidence.read(directory: own, since: start) == nil)
        let plan = CopilotCLIRuntime.buildCommand(executablePath: "/bin/copilot", prompt: "Synthetic", model: "gpt-5",
            workspacePath: root.path, additionalPaths: [], permissionPolicy: .restricted, allowedTools: [],
            timeoutSeconds: 10, capabilities: CopilotCLICapabilities(helpText: "--log-dir DIR"),
            taskEnvironment: [:], copilotHome: root.path, diagnosticLogDirectory: own, permissionArguments: [])
        let index = try #require(plan.arguments.firstIndex(of: "--log-dir"))
        #expect(plan.arguments[index + 1] == own)
        #expect(own != other)
    }

}
