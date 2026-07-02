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
