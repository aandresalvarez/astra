import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeDeliverableVerificationContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task deliverable verification")
@MainActor
struct TaskDeliverableVerificationServiceTests {
    @Test("valid standalone HTML with checked JavaScript reaches syntax verified")
    func validHTMLWithJavaScriptReachesSyntaxVerified() async throws {
        let fixture = try makeFixture(goal: "create a web page with html and javascript")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let html = """
        <!doctype html>
        <html>
        <body>
        <h1>Demo</h1>
        <script>
        function solve() { return true; }
        </script>
        </body>
        </html>
        """
        try html.write(
            toFile: (fixture.folder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: TaskDeliverableVerificationEnvironment(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.status == "passed")
        #expect(result.level == .syntaxVerified)
        #expect(TaskCompletionPolicy.decide(deliverableVerification: result).canComplete)
        #expect(result.checks.contains { $0.id.hasPrefix("javascript.syntax") && $0.status == .passed })
    }

    @Test("invalid JavaScript hard blocks completion")
    func invalidJavaScriptHardBlocksCompletion() async throws {
        let fixture = try makeFixture(goal: "create a web page with html and javascript")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let html = """
        <!doctype html>
        <html><body><script>function broken( { return true; }</script></body></html>
        """
        try html.write(
            toFile: (fixture.folder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: TaskDeliverableVerificationEnvironment(
                checkJavaScriptSyntax: { _, _ in .failed("Unexpected token") }
            )
        )

        #expect(!result.canComplete)
        #expect(result.status == "failed")
        #expect(result.level == .failed)
        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        #expect(decision.shouldBlockCompletion)
        #expect(decision.stopReason == "deliverable_verification_failed")
        #expect(result.userVisibleFailureMessage.contains("failed deterministic verification"))
    }

    @Test("unavailable JavaScript checker requests review instead of failing task")
    func unavailableJavaScriptCheckerRequestsReview() async throws {
        let fixture = try makeFixture(goal: "create a web page with html and javascript")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let html = """
        <!doctype html>
        <html><body><script>function ok() { return true; }</script></body></html>
        """
        try html.write(
            toFile: (fixture.folder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: TaskDeliverableVerificationEnvironment(
                checkJavaScriptSyntax: { _, _ in .unavailable("JavaScript checker unavailable") }
            )
        )

        #expect(result.canComplete)
        #expect(result.status == "review_needed")
        #expect(result.requiresHumanReview)
        #expect(result.level == .needsHumanReview)
        #expect(result.checks.contains { $0.id.hasPrefix("javascript.syntax") && $0.status == .warning })
    }

    @Test("missing required artifact stays a hard blocker")
    func missingRequiredArtifactHardBlocks() async throws {
        let fixture = try makeFixture(goal: "create a json file named config.json")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: TaskDeliverableVerificationEnvironment(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(!result.canComplete)
        #expect(result.level == .noArtifact)
        #expect(result.status == "failed")
        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        #expect(decision.shouldBlockCompletion)
        #expect(decision.stopReason == "no_usable_result")
        #expect(result.checks.contains { $0.id == "artifact.discovery" && $0.status == .failed })
    }

    @Test("named deliverable list without action words hard blocks when missing")
    func namedDeliverableListWithoutActionWordsHardBlocksWhenMissing() async throws {
        let fixture = try makeFixture(goal: """
        Final deliverables:
        - ./results.txt
        """)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: TaskDeliverableVerificationEnvironment(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(!result.canComplete)
        #expect(result.status == "failed")
        #expect(result.level == .noArtifact)
        #expect(result.summary.contains("Missing explicitly requested deliverable file: results.txt."))
        #expect(!result.summary.contains("standalone file artifact"))
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files"
                && check.status == .failed
                && check.summary.contains("results.txt")
        })
        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        #expect(decision.shouldBlockCompletion)
        #expect(decision.stopReason == "no_usable_result")
    }

    @Test("invalid JSON hard blocks completion")
    func invalidJSONHardBlocksCompletion() async throws {
        let fixture = try makeFixture(goal: "create a json file named config.json")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "{ invalid".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run
        )

        #expect(!result.canComplete)
        #expect(result.level == .failed)
        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        #expect(decision.shouldBlockCompletion)
        #expect(decision.stopReason == "deliverable_verification_failed")
        #expect(result.checks.contains { $0.id == "json.syntax" && $0.status == .failed })
    }

    @Test("generic artifact can complete but records human review need")
    func genericArtifactRequiresHumanReview() async throws {
        let fixture = try makeFixture(goal: "create a binary artifact file")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try Data([0x00, 0x01, 0x02]).write(
            to: URL(fileURLWithPath: fixture.folder).appendingPathComponent("artifact.bin")
        )

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run
        )

        #expect(result.canComplete)
        #expect(result.status == "review_needed")
        #expect(result.requiresHumanReview)
        #expect(result.level == .needsHumanReview)
        #expect(TaskCompletionPolicy.decide(deliverableVerification: result).canComplete)
    }

    @Test("verification accepts workspace-root artifacts recorded as run file changes")
    func verificationAcceptsWorkspaceRootArtifactsRecordedAsRunFileChanges() async throws {
        let fixture = try makeFixture(goal: """
        Complete this small filesystem task.
        Create these final deliverables in the current working directory:
        - ./word_counter.py
        - ./sample.txt
        - ./results.txt
        """)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let wordCounter = (fixture.root as NSString).appendingPathComponent("word_counter.py")
        let sample = (fixture.root as NSString).appendingPathComponent("sample.txt")
        let results = (fixture.root as NSString).appendingPathComponent("results.txt")

        try """
        import sys
        from collections import Counter
        text = open(sys.argv[1]).read().lower().split()
        for word, count in Counter(text).most_common(5):
            print(f"{word}: {count}")
        """.write(toFile: wordCounter, atomically: true, encoding: .utf8)
        try "alpha beta alpha gamma".write(toFile: sample, atomically: true, encoding: .utf8)
        try "alpha: 2\nbeta: 1".write(toFile: results, atomically: true, encoding: .utf8)

        for path in [wordCounter, sample, results] {
            fixture.run.appendFileChange(StoredFileChange(
                path: path,
                changeType: StoredFileChangeKind.write.rawValue,
                content: try String(contentsOfFile: path, encoding: .utf8),
                oldString: nil,
                newString: nil,
                timestamp: Date()
            ))
        }

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.status != "failed")
        #expect(result.evidencePaths.contains { $0.hasSuffix("word_counter.py") })
        #expect(result.evidencePaths.contains { $0.hasSuffix("sample.txt") })
        #expect(result.evidencePaths.contains { $0.hasSuffix("results.txt") })
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files" && check.status == .passed
        })
    }

    @Test("missing explicitly requested deliverable file hard blocks completion")
    func missingExplicitlyRequestedDeliverableFileHardBlocksCompletion() async throws {
        let fixture = try makeFixture(goal: """
        Complete this small filesystem task.
        Create these final deliverables in the current working directory:
        - ./word_counter.py
        - ./sample.txt
        - ./results.txt
        """)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let wordCounter = (fixture.root as NSString).appendingPathComponent("word_counter.py")
        let sample = (fixture.root as NSString).appendingPathComponent("sample.txt")

        try """
        import sys
        print(open(sys.argv[1]).read())
        """.write(toFile: wordCounter, atomically: true, encoding: .utf8)
        try "alpha beta alpha gamma".write(toFile: sample, atomically: true, encoding: .utf8)

        for path in [wordCounter, sample] {
            fixture.run.appendFileChange(StoredFileChange(
                path: path,
                changeType: StoredFileChangeKind.write.rawValue,
                content: try String(contentsOfFile: path, encoding: .utf8),
                oldString: nil,
                newString: nil,
                timestamp: Date()
            ))
        }

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(!result.canComplete)
        #expect(result.status == "failed")
        #expect(result.level == .failed)
        #expect(result.evidencePaths.contains { $0.hasSuffix("word_counter.py") })
        #expect(result.evidencePaths.contains { $0.hasSuffix("sample.txt") })
        #expect(!result.evidencePaths.contains { $0.hasSuffix("results.txt") })
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files"
                && check.status == .failed
                && check.summary.contains("results.txt")
        })
        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        #expect(decision.shouldBlockCompletion)
        #expect(decision.stopReason == "deliverable_verification_failed")
    }

    @Test("explicit deliverable line does not require command input filenames")
    func explicitDeliverableLineDoesNotRequireCommandInputFilenames() async throws {
        let fixture = try makeFixture(goal: """
        Create this final deliverable:
        - ./results.txt: captured output from running `python3 word_counter.py sample.txt`.
        """)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let results = (fixture.root as NSString).appendingPathComponent("results.txt")
        try "alpha: 2\nbeta: 1".write(toFile: results, atomically: true, encoding: .utf8)
        fixture.run.appendFileChange(StoredFileChange(
            path: results,
            changeType: StoredFileChangeKind.write.rawValue,
            content: try String(contentsOfFile: results, encoding: .utf8),
            oldString: nil,
            newString: nil,
            timestamp: Date()
        ))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.status != "failed")
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files"
                && check.status == .passed
                && !check.summary.contains("word_counter.py")
                && !check.summary.contains("sample.txt")
        })
    }

    @Test("prose output line does not require input filenames")
    func proseOutputLineDoesNotRequireInputFilenames() async throws {
        let fixture = try makeFixture(goal: "Create summary.md from data.csv.")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let summary = (fixture.root as NSString).appendingPathComponent("summary.md")
        try "# Summary\n\nDone.".write(toFile: summary, atomically: true, encoding: .utf8)
        fixture.run.appendFileChange(StoredFileChange(
            path: summary,
            changeType: StoredFileChangeKind.write.rawValue,
            content: try String(contentsOfFile: summary, encoding: .utf8),
            oldString: nil,
            newString: nil,
            timestamp: Date()
        ))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.status != "failed")
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files"
                && check.status == .passed
                && !check.summary.contains("data.csv")
        })
    }

    @Test("input-first prose output line does not require input filenames")
    func inputFirstProseOutputLineDoesNotRequireInputFilenames() async throws {
        let fixture = try makeFixture(goal: "Use data.csv to create summary.md.")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let summary = (fixture.root as NSString).appendingPathComponent("summary.md")
        try "# Summary\n\nDone.".write(toFile: summary, atomically: true, encoding: .utf8)
        fixture.run.appendFileChange(StoredFileChange(
            path: summary,
            changeType: StoredFileChangeKind.write.rawValue,
            content: try String(contentsOfFile: summary, encoding: .utf8),
            oldString: nil,
            newString: nil,
            timestamp: Date()
        ))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: fixture.run,
            environment: .init(checkJavaScriptSyntax: { _, _ in .passed })
        )

        #expect(result.canComplete)
        #expect(result.status != "failed")
        #expect(result.checks.contains { check in
            check.id == "artifact.required_files"
                && check.status == .passed
                && !check.summary.contains("data.csv")
        })
    }

    @Test("deliverable event payload round trips through typed decoder")
    func deliverableEventPayloadRoundTripsThroughTypedDecoder() throws {
        let runID = UUID()
        let result = TaskDeliverableVerificationResult(
            version: 1,
            profile: .standaloneWebArtifact,
            level: .syntaxVerified,
            status: "passed",
            canComplete: true,
            requiresHumanReview: false,
            summary: "Verified index.html.",
            checks: [
                TaskDeliverableCheck(
                    id: "javascript.syntax",
                    title: "JavaScript syntax",
                    status: .passed,
                    summary: "Syntax passed.",
                    path: "index.html"
                )
            ],
            evidencePaths: ["index.html"],
            runID: runID,
            verifiedAt: Date(timeIntervalSince1970: 1_700)
        )

        let encoded = TaskDeliverableVerificationService.encode(result)
        switch TaskDeliverableVerificationService.decodeResult(encoded) {
        case .success(let decoded):
            #expect(decoded.profile == .standaloneWebArtifact)
            #expect(decoded.level == .syntaxVerified)
            #expect(decoded.status == "passed")
            #expect(decoded.runID == runID)
            #expect(decoded.verifiedAt == Date(timeIntervalSince1970: 1_700))
            #expect(decoded.checks.first?.id == "javascript.syntax")
        case .failure(let error):
            Issue.record("Expected deliverable payload to decode, got \(error)")
        }
    }

    private func makeFixture(goal: String) throws -> (
        root: String,
        container: ModelContainer,
        folder: String,
        task: AgentTask,
        run: TaskRun
    ) {
        let root = try temporaryRoot()
        let container = try makeDeliverableVerificationContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Deliverable Verification", primaryPath: root)
        let task = AgentTask(title: "Deliverable Verification", goal: goal, workspace: workspace)
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.completedAt = Date()
        run.status = .completed
        run.stopReason = "completed"
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        return (root, container, folder, task, run)
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-deliverable-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
