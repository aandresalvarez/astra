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
