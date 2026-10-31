import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Copilot post-process session ownership", .serialized)
@MainActor
struct CopilotSessionDiscoveryWorkerTests {
    @Test("A session omitted from the stream is reserved before settlement", arguments: [false, true])
    func discoveredSessionRemainsProtected(occupied: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        // Distinct subdirectories share real repository guidance, without
        // sharing writable workspaces or requesting Git mutations.
        _ = try await GitService.shared.runGit(at: h.rootURL.path, arguments: ["init", "--quiet"])
        let sessionID = "post-process-session"
        if occupied {
            let holder = try independentTask("holder", in: h)
            let owner = try #require(RuntimeExecutionOwner.acquire(task: holder, context: h.context, maxRunSeconds: 60,
                resourceClaims: policy(for: holder).admittedResourceClaims))
            try owner.prepareLaunch(sessionID: sessionID)
            owner.stopped(proof: nil, turns: 1, tokens: 0, seconds: 1)
            owner.finish()
        }
        let source = h.makeTask(runtime: .copilotCLI, goal: "Reply with the saved result", model: "gpt-5", tokenBudget: 50_000)
        source.workspace?.additionalPaths = []
        let sessionDirectory = h.rootURL.appendingPathComponent(".copilot/session-state/\(sessionID)")
        let executable = try h.writeExecutable(named: "copilot", script: HeadlessChatScenarioTests.copilotScript(body: """
        echo launched >> launches
        mkdir -p \(HeadlessChatScenarioTests.shQuoteSandboxPath(sessionDirectory.path))
        printf '%s\\n' '{"type":"user.message","data":{"content":"Task thread: \(source.id.uuidString)"}}' > \(HeadlessChatScenarioTests.shQuoteSandboxPath(sessionDirectory.appendingPathComponent("events.jsonl").path))
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Saved result"}}'
        printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
        exit 0
        """))
        let worker = h.makeWorker(runtime: .copilotCLI, executablePath: executable, sandboxEnforcementOverride: .strict)
        worker.copilotHome = h.rootURL.appendingPathComponent(".copilot").path
        worker.providerSessionStoreHome = h.rootURL.path
        DirectWorkerLaunchAdmission.admitInitialRun(source, modelContext: h.context)
        await worker.execute(task: source, modelContext: h.context, executionPolicy: policy(for: source)) { _ in }
        let run = try #require(source.runs.first)
        let saved = try #require(try RuntimeExecutionOwner.existing(task: source, context: h.context))
        #expect(run.providerSessionId == sessionID && source.sessionId == sessionID)
        #expect(saved.sessionID == sessionID)
        #expect(saved.resourcesReleased != true && !saved.canReplace)
        #expect(run.tokensUsed == 6 && saved.limits.tokensSpent >= 6)
        let requested = try #require(RuntimeNativeSessionOwnership.claim(runtime: "copilot_cli", sessionID: sessionID, taskID: UUID()))
        #expect(saved.resourceClaims?.contains { TaskExecutionResourceBroker.conflicts($0, requested) } == true)
        if occupied {
            #expect(saved.sessionVerificationPending == true)
            #expect(run.stopReason == "runtime_recovery_blocked")
            #expect(source.events.contains { $0.payload.contains("held by") && $0.payload.contains(sessionID) })
        } else {
            #expect(run.status == .completed)
            #expect(saved.sessionVerificationPending == false)
            try await assertImportedResumeBlocked(source, worker: worker, harness: h, sessionID: sessionID)
            #expect(try RuntimeExecutionOwner.existing(task: source, context: h.context) == saved)
        }
        let independent = try independentTask("independent", in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: independent, context: h.context, maxRunSeconds: 60,
            resourceClaims: policy(for: independent).admittedResourceClaims))
        defer { owner.finish() }
        try owner.prepareLaunch(sessionID: "independent-session")
        #expect(owner.record.state == .launching)
        #expect(try String(contentsOf: h.workspaceURL.appendingPathComponent("launches"), encoding: .utf8) == "launched\n")
    }

    private func assertImportedResumeBlocked(_ source: AgentTask, worker: AgentRuntimeWorker,
                                            harness h: HeadlessChatHarness, sessionID: String) async throws {
        let workspace = try #require(source.workspace)
        var exported = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: h.context))
        exported.id = UUID().uuidString
        exported.name = "Imported independent workspace"
        let path = h.rootURL.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        exported.primaryPath = path.path
        let imported = WorkspaceConfigManager.importWorkspace(from: exported, modelContext: h.context)
        let copy = try #require(imported.tasks.first)
        // Model import after an app restart: only the copied history predates
        // startup. The source's actual process/tool receipt remains untouched.
        let startup = try #require(RuntimeRecoveryLegacyReconciliation.appStartedAt)
        for run in copy.runs {
            run.startedAt = startup.addingTimeInterval(-120)
            run.completedAt = startup.addingTimeInterval(-60)
        }
        try h.context.save()
        #expect(copy.id == source.id && copy.persistentModelID != source.persistentModelID && copy.sessionId == sessionID)
        _ = await h.continueTask(task: copy, message: "Continue with the saved result", worker: worker, executionPolicy: policy(for: copy))
        let latest = try #require(copy.runs.max { $0.startedAt < $1.startedAt })
        let prior = try #require(copy.runs.first { $0.id != latest.id })
        #expect(ProviderLaunchSignatureService.storedSignature(for: copy, run: latest)?.signatureValue
            == ProviderLaunchSignatureService.storedSignature(for: copy, run: prior)?.signatureValue)
        #expect(latest.stopReason == "runtime_recovery_blocked")
        #expect(copy.events.contains { $0.payload.contains("native session \(sessionID)") && $0.payload.contains("held by") })
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("launches").path))
        let receipt = try #require(try RuntimeExecutionOwner.existing(task: copy, context: h.context))
        #expect((receipt.providerLaunchCount ?? 0) == 0)
    }

    private func policy(for task: AgentTask) -> AgentRuntimeExecutionPolicy {
        .default.withResourceAdmission(workspaceAccess: .exclusive, sandboxEnforcement: .strict,
            claims: TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
                runMode: "request", fallbackAccess: .write, sandboxEnforcement: .strict))
    }

    private func independentTask(_ name: String, in h: HeadlessChatHarness) throws -> AgentTask {
        let path = h.rootURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, primaryPath: path.path)
        let task = AgentTask(title: name, goal: "Independent session", workspace: workspace, runtime: .copilotCLI)
        h.context.insert(workspace); h.context.insert(task)
        try h.context.save()
        return task
    }
}
