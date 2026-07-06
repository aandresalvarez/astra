import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

private func makeInferredValidationContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task inferred validation")
@MainActor
struct TaskInferredValidationServiceTests {
    @Test("inferred validation suggests artifact and optional content checks")
    func inferredValidationSuggestsArtifactAndContentChecks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "<html><body><h1>Masterball Solver</h1></body></html>".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let suggestion = try #require(TaskInferredValidationService.suggestion(for: fixture.task))
        let assertions = try #require(suggestion.plan.validationContract?.assertions)

        #expect(suggestion.artifactCount == 1)
        #expect(assertions.contains {
            $0.method == .artifact &&
                $0.required &&
                $0.path == "index.html"
        })
        #expect(assertions.contains {
            $0.method == .textContains &&
                !$0.required &&
                $0.evidenceQuery?.localizedCaseInsensitiveContains("Masterball") == true
        })
        #expect(assertions.contains {
            $0.method == .browserBehavior &&
                !$0.required &&
                $0.path == "index.html"
        })
    }

    @Test("inferred validation records mission control contract without approved plan")
    func inferredValidationRecordsMissionControlContractWithoutApprovedPlan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "<html><body><h1>Masterball Solver</h1></body></html>".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        let result = await TaskInferredValidationService.run(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })

        TaskContextStateManager.refresh(task: fixture.task)
        let state = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        let contract = try #require(state.validationContract)
        #expect(contract.status == "passed")
        #expect(contract.requiredTotal == 1)
        #expect(contract.requiredPassed == 1)
        #expect(contract.assertions.contains {
            $0.method == TaskValidationAssertionMethod.artifact.rawValue &&
                $0.status == "passed"
        })

        let mission = try #require(MissionControlPresentation.build(
            task: fixture.task,
            planState: .empty,
            state: state
        ))
        #expect(mission.validationSummary == "passed: 1/1 required, 3 assertions")
        #expect(mission.statusTitle == "Verified")
    }

    @Test("inferred validation is unavailable without artifacts")
    func inferredValidationUnavailableWithoutArtifacts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        #expect(TaskInferredValidationService.suggestion(for: fixture.task) == nil)
    }

    @Test("automatic baseline records inferred verification for completed manual artifacts")
    func automaticBaselineRecordsInferredVerificationForCompletedManualArtifacts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "Masterball notes".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        #expect(TaskInferredValidationService.shouldRunAutomaticBaseline(for: fixture.task))

        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractCreated })
        #expect(fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("automatic baseline skips when a validation contract already exists")
    func automaticBaselineSkipsWhenValidationContractAlreadyExists() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "Masterball notes".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            type: TaskValidationEventTypes.contractCreated,
            payload: "{}"
        ))

        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(!result.didRun)
        #expect(!fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("automatic baseline skips after terminal deliverable verification")
    func automaticBaselineSkipsAfterTerminalDeliverableVerification() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "Masterball notes".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            type: TaskDeliverableVerificationEventTypes.passed,
            payload: "{}"
        ))

        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(!result.didRun)
        #expect(!fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("automatic baseline can strengthen deliverable review-needed evidence")
    func automaticBaselineCanStrengthenDeliverableReviewNeededEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try "Masterball notes".write(
            toFile: (fixture.folder as NSString).appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        fixture.context.insert(TaskEvent(
            task: fixture.task,
            type: TaskDeliverableVerificationEventTypes.reviewNeeded,
            payload: "{}"
        ))

        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(fixture.task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    private func makeFixture() throws -> (
        root: String,
        context: ModelContext,
        folder: String,
        task: AgentTask,
        run: TaskRun
    ) {
        let root = try temporaryRoot()
        let container = try makeInferredValidationContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Inferred Validation", primaryPath: root)
        let task = AgentTask(
            title: "Create Masterball puzzle web solver",
            goal: "create a web page with a masterball and a solver in javascript",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.completedAt = Date()
        run.status = .completed
        run.stopReason = "completed"
        task.status = .completed
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        return (root, context, folder, task, run)
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-inferred-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
