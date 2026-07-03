import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Action Executor connector reads")
struct WorkspaceAppActionExecutorConnectorReadTests {
    @MainActor
    @Test("capability read pipeline normalizes connector limits before resolving")
    func capabilityReadPipelineNormalizesConnectorLimitsBeforeResolving() async throws {
        let fixture = try WorkspaceAppActionExecutorTests.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binding = WorkspaceAppActionExecutorTests.warehouseBinding(for: fixture)
        let client = CapturingWorkspaceAppCapabilitySourceClient(rows: [
            ["participant_id": .text("P-001")]
        ])
        let pipeline = WorkspaceAppCapabilityReadPipeline(
            sourceResolver: WorkspaceAppSourceResolver(
                capabilityClient: client,
                asyncCapabilityClient: client
            ),
            readPolicy: WorkspaceAppReadPolicy(
                rateLimiter: WorkspaceAppConnectorReadRateLimiter(maxPerWindow: 10, window: 60)
            )
        )
        let action = fixture.manifest.actions.first { $0.id == "readWarehouse" }!

        _ = try pipeline.resolve(WorkspaceAppCapabilityReadRequest(
            action: action,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(),
            surface: .executor
        ))
        _ = try pipeline.resolve(WorkspaceAppCapabilityReadRequest(
            action: action,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(limit: 100_000),
            surface: .executor
        ))
        _ = try await pipeline.resolveAsync(WorkspaceAppCapabilityReadRequest(
            action: action,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(),
            surface: .executor
        ))
        _ = try await pipeline.resolveAsync(WorkspaceAppCapabilityReadRequest(
            action: action,
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: fixture.manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppActionInput(limit: 100_000),
            surface: .executor
        ))

        #expect(client.observedLimits == [
            WorkspaceAppReadPolicy.defaultConnectorReadLimit,
            WorkspaceAppReadPolicy.maxConnectorReadLimit,
            WorkspaceAppReadPolicy.defaultConnectorReadLimit,
            WorkspaceAppReadPolicy.maxConnectorReadLimit
        ])
    }

    @MainActor
    @Test("executeAsync runs connector-read pipeline steps through the async resolver")
    func executeAsyncRunsConnectorReadPipelineStepsThroughAsyncResolver() async throws {
        let fixture = try WorkspaceAppActionExecutorTests.makePublishedApp(permissionMode: .readOnly)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "readPipeline",
            type: "pipeline.run",
            label: "Read Pipeline",
            steps: ["readWarehouse"]
        ))
        let binding = WorkspaceAppActionExecutorTests.warehouseBinding(for: fixture)
        let client = CapturingWorkspaceAppCapabilitySourceClient(rows: [
            ["participant_id": .text("P-001")]
        ])
        let executor = WorkspaceAppActionExecutor(
            sourceResolver: WorkspaceAppSourceResolver(asyncCapabilityClient: client),
            readPolicy: WorkspaceAppReadPolicy(
                rateLimiter: WorkspaceAppConnectorReadRateLimiter(maxPerWindow: 10, window: 60)
            )
        )

        let result = try await executor.executeAsync(
            actionID: "readPipeline",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: manifest,
            dependencyBindings: [binding],
            modelContext: fixture.context
        )

        #expect(result.run.status == .completed)
        #expect(result.rows == [["participant_id": .text("P-001")]])
        #expect(client.syncReadCount == 0)
        #expect(client.asyncReadCount == 1)
    }

    @MainActor
    @Test("executeAsync routes connector-read workflow writes through the async writer")
    func executeAsyncRoutesConnectorReadWorkflowWritesThroughAsyncWriter() async throws {
        let fixture = try WorkspaceAppActionExecutorTests.makePublishedApp(permissionMode: .preApproved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = fixture.manifest
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "readThenSubmit",
            type: "pipeline.run",
            label: "Read Then Submit",
            steps: ["readWarehouse", "submitRedcapRecord"]
        ))
        let readBinding = WorkspaceAppActionExecutorTests.warehouseBinding(for: fixture)
        let writeBinding = WorkspaceAppDependencyBinding(
            workspaceID: fixture.workspace.id,
            appID: fixture.app.id,
            appLogicalID: fixture.app.logicalID,
            requirementID: "redcapWrite",
            contract: "recordProject.write",
            operations: ["submitCreate"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-write-native",
            provider: "redcap",
            transport: .native
        )
        let readClient = CapturingWorkspaceAppCapabilitySourceClient(rows: [
            ["participant_id": .text("P-001")]
        ])
        let writeClient = CapturingWorkspaceAppAsyncWriteClient(result: WorkspaceAppCapabilityWriteResult(
            outputSummary: "Imported 1 record",
            rows: [["status": .text("submitted")]]
        ))
        let executor = WorkspaceAppActionExecutor(
            sourceResolver: WorkspaceAppSourceResolver(asyncCapabilityClient: readClient),
            asyncCapabilityWriteClient: writeClient,
            readPolicy: WorkspaceAppReadPolicy(
                rateLimiter: WorkspaceAppConnectorReadRateLimiter(maxPerWindow: 10, window: 60)
            )
        )

        let result = try await executor.executeAsync(
            actionID: "readThenSubmit",
            app: fixture.app,
            workspace: fixture.workspace,
            manifest: manifest,
            dependencyBindings: [readBinding, writeBinding],
            modelContext: fixture.context
        )

        #expect(result.run.status == WorkspaceAppRunStatus.completed)
        #expect(readClient.asyncReadCount == 1)
        #expect(writeClient.writeCount == 1)
        let expectedRecords: [[String: WorkspaceAppStorageValue]] = [
            ["participant_id": .text("P-001")]
        ]
        #expect(writeClient.records == expectedRecords)
    }
}

private final class CapturingWorkspaceAppCapabilitySourceClient:
    WorkspaceAppCapabilitySourceClient,
    WorkspaceAppAsyncCapabilitySourceClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let rows: [[String: WorkspaceAppStorageValue]]
    private var limits: [Int] = []
    private var syncReads = 0
    private var asyncReads = 0

    init(rows: [[String: WorkspaceAppStorageValue]]) {
        self.rows = rows
    }

    var observedLimits: [Int] {
        lock.lock()
        let snapshot = limits
        lock.unlock()
        return snapshot
    }

    var syncReadCount: Int {
        lock.lock()
        let count = syncReads
        lock.unlock()
        return count
    }

    var asyncReadCount: Int {
        lock.lock()
        let count = asyncReads
        lock.unlock()
        return count
    }

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        record(input.limit, async: false)
        return rows
    }

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        record(input.limit, async: true)
        return rows
    }

    private func record(_ limit: Int, async: Bool) {
        lock.lock()
        limits.append(limit)
        if async {
            asyncReads += 1
        } else {
            syncReads += 1
        }
        lock.unlock()
    }
}

private final class CapturingWorkspaceAppAsyncWriteClient:
    WorkspaceAppAsyncCapabilityWriteClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: WorkspaceAppCapabilityWriteResult
    private var writes = 0
    private var observedRecords: [[String: WorkspaceAppStorageValue]] = []

    init(result: WorkspaceAppCapabilityWriteResult) {
        self.result = result
    }

    var writeCount: Int {
        lock.lock()
        let count = writes
        lock.unlock()
        return count
    }

    var records: [[String: WorkspaceAppStorageValue]] {
        lock.lock()
        let snapshot = observedRecords
        lock.unlock()
        return snapshot
    }

    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) async throws -> WorkspaceAppCapabilityWriteResult {
        record(input.effectiveRecord)
        return result
    }

    private func record(_ record: [String: WorkspaceAppStorageValue]) {
        lock.lock()
        writes += 1
        observedRecords.append(record)
        lock.unlock()
    }
}
