import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Human-in-the-loop: a pipeline that reaches an un-approved `gate.humanApproval` step suspends the
/// run to `.waiting` pending a human decision (the actionable approval queue), then resumes on
/// approve or fails on reject — and a later gate re-prompts rather than inheriting the approval.
@Suite("Workspace App Approval Queue")
struct WorkspaceAppApprovalQueueTests {
    @MainActor
    private struct Env {
        var container: ModelContainer
        var workspace: Workspace
        var context: ModelContext
        var root: URL
    }

    @MainActor
    private static func makeEnv() throws -> Env {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsapp-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)
        return Env(container: container, workspace: workspace, context: context, root: root)
    }

    private func gate(_ id: String) -> WorkspaceAppActionSpec {
        WorkspaceAppActionSpec(id: id, type: "gate.humanApproval", label: id,
                               approvalPrompt: "Proceed with \(id)?", approvalDecisions: ["approve", "reject"])
    }

    private func manifest(steps: [String], gates: [String]) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "approver", name: "Approver"),
            actions: gates.map(gate) + [WorkspaceAppActionSpec(id: "run", type: "pipeline.run", label: "Run", steps: steps)],
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
    }

    @MainActor
    @Test("a pipeline suspends on a human-approval gate to .waiting with the pending gate id")
    func suspendsForApproval() throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let m = manifest(steps: ["approve"], gates: ["approve"])
        let created = try WorkspaceAppService().createApp(manifest: m, in: env.workspace, modelContext: env.context, status: .published)
        let result = try WorkspaceAppActionExecutor().execute(
            actionID: "run", app: created.app, workspace: env.workspace, manifest: m,
            input: WorkspaceAppActionInput(), modelContext: env.context
        )
        #expect(result.run.status == .waiting)
        #expect(result.run.pendingApprovalActionID == "approve")
    }

    @MainActor
    @Test("approving a pending gate resumes the pipeline to completion")
    func approveResumes() async throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let m = manifest(steps: ["approve"], gates: ["approve"])
        let created = try WorkspaceAppService().createApp(manifest: m, in: env.workspace, modelContext: env.context, status: .published)
        let executor = WorkspaceAppActionExecutor()
        let waiting = try executor.execute(actionID: "run", app: created.app, workspace: env.workspace, manifest: m, input: WorkspaceAppActionInput(), modelContext: env.context)
        let resumed = try await executor.resumeWithApproval(run: waiting.run, approved: true, app: created.app, workspace: env.workspace, manifest: m, modelContext: env.context)
        #expect(resumed.run.status == .completed)
        #expect(resumed.run.pendingApprovalActionID == nil)
    }

    @MainActor
    @Test("rejecting a pending gate fails the run")
    func rejectFails() async throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let m = manifest(steps: ["approve"], gates: ["approve"])
        let created = try WorkspaceAppService().createApp(manifest: m, in: env.workspace, modelContext: env.context, status: .published)
        let executor = WorkspaceAppActionExecutor()
        let waiting = try executor.execute(actionID: "run", app: created.app, workspace: env.workspace, manifest: m, input: WorkspaceAppActionInput(), modelContext: env.context)
        let resumed = try await executor.resumeWithApproval(run: waiting.run, approved: false, app: created.app, workspace: env.workspace, manifest: m, modelContext: env.context)
        #expect(resumed.run.status == .failed)
    }

    @MainActor
    @Test("a second human gate re-prompts rather than inheriting the first approval")
    func laterGateRePrompts() async throws {
        let env = try Self.makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let m = manifest(steps: ["g1", "g2"], gates: ["g1", "g2"])
        let created = try WorkspaceAppService().createApp(manifest: m, in: env.workspace, modelContext: env.context, status: .published)
        let executor = WorkspaceAppActionExecutor()
        let waiting = try executor.execute(actionID: "run", app: created.app, workspace: env.workspace, manifest: m, input: WorkspaceAppActionInput(), modelContext: env.context)
        #expect(waiting.run.pendingApprovalActionID == "g1")
        // Approving g1 should pause again at g2, not auto-approve it.
        let afterFirst = try await executor.resumeWithApproval(run: waiting.run, approved: true, app: created.app, workspace: env.workspace, manifest: m, modelContext: env.context)
        #expect(afterFirst.run.status == .waiting)
        #expect(afterFirst.run.pendingApprovalActionID == "g2")
        // Approving g2 completes it.
        let afterSecond = try await executor.resumeWithApproval(run: afterFirst.run, approved: true, app: created.app, workspace: env.workspace, manifest: m, modelContext: env.context)
        #expect(afterSecond.run.status == .completed)
    }
}
