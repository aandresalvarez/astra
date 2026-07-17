import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport
@testable import ASTRA

@Suite("Task external operation registration", .serialized)
@MainActor
struct TaskExternalOperationRegistrationServiceTests {
    @Test("structured start result binds exact tool pair and registers once")
    func structuredResultRegistersExactlyOnce() throws {
        let fixture = try RegistrationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.createBackendRecord(
            invocationID: "inner-mcp-json-rpc-7",
            command: "printf '%s' super-secret-value"
        )
        let content = try fixture.structuredResult(for: record)

        let first = TaskExternalOperationRegistrationService.registerStructuredStartResult(
            content,
            toolResultID: "outer-provider-tool-use-42",
            observedToolName: "mcp__astra_workspace__workspace_job_start",
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )
        let second = TaskExternalOperationRegistrationService.registerStructuredStartResult(
            content,
            toolResultID: "outer-provider-tool-use-42",
            observedToolName: "mcp__astra_workspace__workspace_job_start",
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        )

        guard case .registered = first else {
            Issue.record("Expected first trusted result to register")
            return
        }
        guard case .alreadyRegistered = second else {
            Issue.record("Expected duplicate trusted result to be idempotent")
            return
        }
        let operations = try fixture.context.fetch(FetchDescriptor<TaskExternalOperation>())
        let operation = try #require(operations.first)
        #expect(operations.count == 1)
        #expect(operation.externalIdentity == record.startReceipt?.externalIdentity)
        #expect(operation.originatingRunID == fixture.run.id)
        #expect(operation.backendJobID == record.jobID)
        let controlPlaneProjection = [
            operation.externalIdentity,
            operation.backendKindRaw,
            operation.backendJobID,
            operation.originatingContextRevision ?? ""
        ].joined(separator: "|")
        #expect(!controlPlaneProjection.contains("super-secret-value"))
    }

    @Test("crash after launch adopts trusted backend record exactly once")
    func crashWindowAdoptsExactlyOnce() throws {
        let fixture = try RegistrationFixture()
        defer { fixture.cleanup() }
        _ = try fixture.createBackendRecord(invocationID: "inner-mcp-json-rpc-8")

        let first = TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
            task: fixture.task,
            modelContext: fixture.context
        )
        let second = TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
            task: fixture.task,
            modelContext: fixture.context
        )

        #expect(first.count == 1)
        #expect(second.count == 1)
        guard case .registered = first[0], case .alreadyRegistered = second[0] else {
            Issue.record("Expected registration followed by idempotent adoption")
            return
        }
        #expect(try fixture.context.fetchCount(FetchDescriptor<TaskExternalOperation>()) == 1)
    }

    @Test("terminal backend records register directly into retryable delivery states")
    func terminalRecordsRegisterIntoDeliveryStates() throws {
        let fixture = try RegistrationFixture()
        defer { fixture.cleanup() }
        let succeeded = try fixture.createBackendRecord(invocationID: "terminal-success")
        let failed = try fixture.createBackendRecord(invocationID: "terminal-failure")
        let store = WorkspaceManagedJobStore(rootPath: fixture.jobRoot.path)
        _ = try store.mark(jobID: succeeded.jobID, status: .succeeded, exitCode: 0)
        _ = try store.mark(jobID: failed.jobID, status: .failed, exitCode: 1)

        let outcomes = TaskExternalOperationRegistrationService.reconcileTrustedBackendRecords(
            task: fixture.task,
            modelContext: fixture.context,
            now: Date(timeIntervalSince1970: 9_000)
        )
        let operations = try fixture.context.fetch(FetchDescriptor<TaskExternalOperation>())
        let succeededOperation = try #require(operations.first { $0.backendJobID == succeeded.jobID })
        let failedOperation = try #require(operations.first { $0.backendJobID == failed.jobID })

        #expect(outcomes.count == 2)
        #expect(succeededOperation.executionState == .processCompleted)
        #expect(succeededOperation.monitoringState == .validating)
        #expect(succeededOperation.nextCheckAt == nil)
        #expect(succeededOperation.terminalObservedAt == Date(timeIntervalSince1970: 9_000))
        #expect(failedOperation.executionState == .failed)
        #expect(failedOperation.monitoringState == .completed)
        #expect(failedOperation.nextCheckAt == nil)
        #expect(failedOperation.terminalObservedAt == Date(timeIntervalSince1970: 9_000))
    }

    @Test("untrusted malformed traversal and symlink-substituted results are rejected")
    func rejectsUntrustedAndSubstitutedResults() throws {
        let fixture = try RegistrationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.createBackendRecord(invocationID: "inner-mcp-json-rpc-9")
        let content = try fixture.structuredResult(for: record)

        #expect(TaskExternalOperationRegistrationService.registerStructuredStartResult(
            content,
            toolResultID: "outer-9",
            observedToolName: "workspace_job_status",
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        ) == .rejected)

        var traversal = try #require(
            JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
        traversal["jobID"] = "../escape"
        traversal["secret"] = "must-not-be-accepted"
        let traversalContent = String(
            decoding: try JSONSerialization.data(withJSONObject: traversal),
            as: UTF8.self
        )
        #expect(TaskExternalOperationRegistrationService.registerStructuredStartResult(
            traversalContent,
            toolResultID: "outer-9",
            observedToolName: "workspace_job_start",
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        ) == .rejected)

        let metadata = fixture.jobRoot
            .appendingPathComponent(record.jobID, isDirectory: true)
            .appendingPathComponent("job.json", isDirectory: false)
        let outside = fixture.root.appendingPathComponent("outside-job.json", isDirectory: false)
        try Data(content.utf8).write(to: outside)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
        #expect(TaskExternalOperationRegistrationService.registerStructuredStartResult(
            content,
            toolResultID: "outer-9",
            observedToolName: "workspace_job_start",
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context
        ) == .rejected)
        #expect(try fixture.context.fetchCount(FetchDescriptor<TaskExternalOperation>()) == 0)
    }

    @Test("workspace import quarantines active operation without executable details")
    func importQuarantinesActiveRegistration() throws {
        let fixture = try RegistrationFixture()
        defer { fixture.cleanup() }
        let operation = TaskExternalOperation(
            taskID: fixture.task.id,
            externalIdentity: "docker_workspace_job:import-safe",
            originatingRunID: fixture.run.id,
            backendKindRaw: WorkspaceManagedJobStartReceipt.backend,
            backendJobID: "job-safe",
            executionState: .running,
            observationHealth: .healthy,
            monitoringState: .active,
            nextCheckAt: Date()
        )
        fixture.context.insert(operation)
        let config = try #require(WorkspaceConfigManager.export(
            workspace: fixture.workspace,
            modelContext: fixture.context
        ))

        let importedContainer = try RegistrationFixture.makeContainer()
        let importedContext = importedContainer.mainContext
        let importedWorkspace = WorkspaceConfigManager.importWorkspace(
            from: config,
            modelContext: importedContext
        )
        let importedTask = try #require(importedWorkspace.tasks.first)
        let importedOperation = try #require(
            try importedContext.fetch(FetchDescriptor<TaskExternalOperation>()).first
        )

        #expect(importedTask.status == .waitingExternal)
        #expect(importedOperation.monitoringState == .quarantined)
        #expect(importedOperation.observationHealth == .quarantined)
        #expect(importedOperation.nextCheckAt == nil)
        #expect(importedOperation.leaseOwner == nil)
        #expect(importedOperation.leaseExpiresAt == nil)
    }
}

@MainActor
private final class RegistrationFixture {
    let root: URL
    let jobRoot: URL
    let container: ModelContainer
    let context: ModelContext
    let workspace: Workspace
    let task: AgentTask
    let run: TaskRun

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-external-registration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        container = try Self.makeContainer()
        context = container.mainContext
        workspace = Workspace(name: "External operation fixture", primaryPath: root.path)
        task = AgentTask(title: "Durable job", goal: "Complete durable work", workspace: workspace)
        run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        jobRoot = URL(
            fileURLWithPath: DockerWorkspaceMCPProjection.jobRootHostPath(task: task),
            isDirectory: true
        )
        try context.save()
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    func createBackendRecord(
        invocationID: String,
        command: String = "sleep 120"
    ) throws -> WorkspaceManagedJobRecord {
        try WorkspaceManagedJobStore(rootPath: jobRoot.path).create(
            command: command,
            timeoutSeconds: 300,
            label: "fixture",
            progressProbe: nil,
            runtime: "docker",
            taskID: task.id.uuidString,
            runID: run.id.uuidString,
            invocationID: invocationID,
            containerName: DockerWorkspaceMCPProjection.containerName(taskID: task.id, runID: run.id)
        )
    }

    func structuredResult(for record: WorkspaceManagedJobRecord) throws -> String {
        let result = try WorkspaceManagedJobStructuredResult(
            jobID: record.jobID,
            status: record.status,
            startReceipt: record.startReceipt
        )
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
