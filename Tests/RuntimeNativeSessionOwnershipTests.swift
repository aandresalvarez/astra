import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Native session ownership", .serialized)
@MainActor
struct RuntimeNativeSessionOwnershipTests {
    private func task(_ name: String, runtime: AgentRuntimeID, in h: HeadlessChatHarness) throws -> AgentTask {
        let path = h.rootURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, primaryPath: path.path)
        h.context.insert(workspace)
        let task = AgentTask(title: name, goal: "Synthetic independent task", workspace: workspace,
            tokenBudget: 10_000, model: "default", runtime: runtime)
        task.maxTurns = 4
        h.context.insert(task)
        try h.context.save()
        return task
    }

    @Test("Independent workspaces may overlap, but one native session has one execution",
          arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func nativeSessionIsExclusive(runtime: AgentRuntimeID) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let first = try task("first", runtime: runtime, in: h)
        let second = try task("second", runtime: runtime, in: h)
        let independent = try task("independent", runtime: runtime, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: first, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch(sessionID: "shared-session")
        let contender = try #require(RuntimeExecutionOwner.acquire(task: second, context: h.context, maxRunSeconds: 60))
        defer { contender.finish() }
        let before = contender.record
        #expect(throws: (any Error).self) { try contender.prepareLaunch(sessionID: "shared-session") }
        #expect(contender.record == before)
        let other = try #require(RuntimeExecutionOwner.acquire(task: independent, context: h.context, maxRunSeconds: 60))
        defer { other.finish() }
        try other.prepareLaunch(sessionID: "independent-session")
        #expect(other.record.state == .launching)
        #expect(owner.record.sessionID == "shared-session")
    }

    @Test("An imported settled history cannot resume a source session with uncertain tools")
    func importedHistoryCannotBypassUncertainSession() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        source.status = .completed
        source.sessionId = "imported-native-session"
        let legacy = TaskRun(task: source)
        let appStartedAt = try #require(RuntimeRecoveryLegacyReconciliation.appStartedAt)
        legacy.startedAt = appStartedAt.addingTimeInterval(-120)
        legacy.completedAt = appStartedAt.addingTimeInterval(-60)
        legacy.status = .completed
        legacy.typedStopReason = .completed
        legacy.providerSessionId = source.sessionId
        h.context.insert(legacy)
        let originalSignature = signature(for: source, run: legacy, in: h.context)
        ProviderLaunchSignatureService.record(originalSignature, task: source, run: legacy, modelContext: h.context)
        try h.context.save()

        let workspace = try #require(source.workspace)
        var exported = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: h.context))
        exported.id = UUID().uuidString
        exported.name = "Imported independent workspace"
        let importedPath = h.rootURL.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: importedPath, withIntermediateDirectories: true)
        exported.primaryPath = importedPath.path
        let imported = WorkspaceConfigManager.importWorkspace(from: exported, modelContext: h.context)
        let copy = try #require(imported.tasks.first)
        #expect(copy.id == source.id)
        #expect(copy.persistentModelID != source.persistentModelID)
        #expect(copy.sessionId == source.sessionId)
        #expect(copy.workspace?.primaryPath != source.workspace?.primaryPath)

        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        try owner.prepareLaunch(sessionID: source.sessionId)
        owner.stopped(proof: nil, turns: 1, tokens: 300, seconds: 2)
        let protectedLimits = owner.record.limits
        owner.finish() // kernel lease ends; uncertainty must still fence the native session
        #expect(owner.record.state == .unverified && owner.record.resourcesReleased != true)

        let contender = try #require(RuntimeExecutionOwner.acquire(task: copy, context: h.context, maxRunSeconds: 60))
        defer { contender.finish() }
        let current = TaskRun(task: copy)
        h.context.insert(current)
        try contender.bind(run: current)
        let currentSignature = signature(for: copy, run: current, in: h.context)
        #expect(currentSignature.signatureValue == originalSignature.signatureValue)
        let decision = ProviderNativeContinuationPolicy.resolve(for: copy, currentRun: current,
            runtimeAdapter: CodexCLIRuntimeAdapter(), phase: .resume, currentLaunchSignature: currentSignature)
        #expect(decision.sessionID == source.sessionId)
        do {
            try contender.prepareLaunch(sessionID: decision.sessionID)
            Issue.record("An imported copy took its source's uncertain native session")
        } catch let conflict as RuntimeNativeSessionOwnership.Conflict {
            #expect(conflict.message.contains("workspace \u{201C}source\u{201D}"))
        }
        #expect((contender.record.providerLaunchCount ?? 0) == 0)
        #expect(try RuntimeExecutionOwner.existing(task: source, context: h.context)?.limits == protectedLimits)

        let third = try task("third", runtime: .codexCLI, in: h)
        let independent = try #require(RuntimeExecutionOwner.acquire(task: third, context: h.context, maxRunSeconds: 60))
        defer { independent.finish() }
        try independent.prepareLaunch(sessionID: "another-session")
    }

    @Test("Session spelling follows continuation normalization without locking another provider")
    func normalizationAndProviderScope() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch(sessionID: "  Session-A\n")
        let other = try task("other", runtime: .codexCLI, in: h)
        let contender = try #require(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60))
        defer { contender.finish() }
        #expect(throws: (any Error).self) { try contender.prepareLaunch(sessionID: "Session-A") }
        try contender.prepareLaunch(sessionID: "session-a") // opaque IDs retain their case
        let claude = try task("claude", runtime: .claudeCode, in: h)
        let independent = try #require(RuntimeExecutionOwner.acquire(task: claude, context: h.context, maxRunSeconds: 60))
        defer { independent.finish() }
        try independent.prepareLaunch(sessionID: "Session-A")
    }

    @Test("Late session signals preserve earlier identities and fallback audit reservations")
    func lateIdentityAndMissingJournal() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        try owner.prepareLaunch(sessionID: "before-drain")
        owner.stopped(proof: nil, turns: 1, tokens: 300, seconds: 2)
        try await owner.session("during-drain")
        let receipt = try #require(owner.receiptURL)
        owner.finish()
        let store = RuntimeExecutionOwner.store(in: h.context)
        try FileManager.default.removeItem(at: receipt)
        let reopened = ModelContext(h.container)
        let claims = try RuntimeResourceOwnership.claims(in: store, context: reopened)
        for session in ["before-drain", "during-drain"] {
            let requested = try #require(RuntimeNativeSessionOwnership.claim(runtime: "codex_cli", sessionID: session, taskID: UUID()))
            #expect(!TaskExecutionResourceBroker.canAcquire([requested], active: claims))
        }
        let independent = try #require(RuntimeNativeSessionOwnership.claim(runtime: "codex_cli", sessionID: "independent", taskID: UUID()))
        #expect(TaskExecutionResourceBroker.canAcquire([independent], active: claims))
    }

    @Test("Legacy retained executions fence every session after reopening the store")
    func retainedSessionProjection() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        try owner.prepareLaunch(sessionID: "original")
        owner.stopped(proof: nil, turns: 1, tokens: 300, seconds: 2)
        var old = owner.record
        owner.finish()
        // Reproduce pre-upgrade receipts: session IDs exist, typed session
        // claims do not. No positive stop proof is invented by this fixture.
        old.resourceClaims?.removeAll { $0.resourceKind == .nativeSession }
        let store = RuntimeExecutionOwner.store(in: h.context)
        try store.retain(old)
        var current = old
        current.executionID = UUID()
        current.sessionID = "continued"
        current.retainedExecutionHead = old.executionID
        do {
            let lease = try store.acquire(taskID: source.id, taskOwnerID: source.persistentModelID)
            try lease.save(current)
        }
        let reopened = ModelContext(h.container)
        let claims = try RuntimeResourceOwnership.claims(in: RuntimeExecutionOwner.store(in: reopened), context: reopened)
        for session in ["original", "continued"] {
            let requested = try #require(RuntimeNativeSessionOwnership.claim(runtime: "codex_cli", sessionID: session, taskID: UUID()))
            #expect(!TaskExecutionResourceBroker.canAcquire([requested], active: claims))
        }
    }

    @Test("An independent admission lease delays session verification without stopping the owner", arguments: [false, true])
    func admissionContention(cancelled: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch()
        let store = RuntimeExecutionOwner.store(in: h.context)
        var unrelatedAdmission: RuntimeExecutionOwnerStore.Lease? = try store.acquireAdmission()
        let verification = Task { try await owner.session("independent-session") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.record.sessionID == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(unrelatedAdmission != nil)
        #expect(owner.record.sessionID == "independent-session")
        // The identity is durable even if the app dies during the short wait.
        let saved = try #require(try RuntimeExecutionOwner.existing(task: source, context: h.context))
        #expect(saved.sessionID == "independent-session" && saved.resourcesReleased == false)
        #expect(saved.inheritedToolUncertainty != true && saved.sessionVerificationPending == true)
        if cancelled { verification.cancel() }
        unrelatedAdmission = nil
        if cancelled {
            do { try await verification.value; Issue.record("Cancelled verification unexpectedly succeeded") }
            catch is CancellationError {}
            #expect(owner.record.inheritedToolUncertainty == true)
            #expect(!owner.record.canReplace)
        } else {
            try await verification.value
            #expect(owner.record.inheritedToolUncertainty != true)
            #expect(owner.record.sessionVerificationPending == false)
            #expect(owner.record.state == .launching)
        }
        let claim = try #require(RuntimeNativeSessionOwnership.claim(owner.record))
        #expect(try RuntimeResourceOwnership.claims(in: store, context: h.context).contains(claim))
    }

    @Test("Admission timeout never takes an occupied lease or authorizes release")
    func admissionTimeout() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let store = RuntimeExecutionOwner.store(in: h.context)
        let held = try store.acquireAdmission()
        defer { withExtendedLifetime(held) {} }
        do {
            _ = try await RuntimeNativeSessionOwnership.admission(in: store, deadline: .now)
            Issue.record("An occupied admission lease was acquired")
        } catch is RuntimeNativeSessionOwnership.AdmissionTimeout {}
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) { try store.acquireAdmission() }
    }

    @Test("A clean process receipt cannot release a session whose identity is still being verified", arguments: [false, true])
    func stopDuringSessionVerification(finishEarly: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch()
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sleep", arguments: ["0.1"],
            currentDirectory: h.rootURL.path, environment: [:], stdinMode: .closed)
        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.yield(()); exited.continuation.finish() }
        try process.run()
        try owner.launched(process)
        let store = RuntimeExecutionOwner.store(in: h.context)
        var unrelatedAdmission: RuntimeExecutionOwnerStore.Lease? = try store.acquireAdmission()
        let wait = RuntimeProviderWait(owner: owner)
        let consumer = Task { await wait.run {
            do { try await owner.session("pending-session"); return AgentProcessResult(exitCode: 0) }
            catch { return AgentProcessResult(exitCode: -1, runtimeStopReason: "runtime_recovery_blocked") }
        } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.record.sessionID == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(unrelatedAdmission != nil && owner.record.sessionVerificationPending == true)
        for await _ in exited.stream { break }
        let proof = try #require(process.stopProof(executionID: owner.record.executionID, toolsStopped: true, remoteWorkExcluded: true))
        #expect(proof.permitsReplacement)
        owner.stopped(proof: proof, turns: 1, tokens: 12, seconds: 0.1)
        owner.requestCancellation()
        #expect(!owner.record.canReplace)
        #expect(!wait.retire(generation: owner.record.ownerID))
        if finishEarly { owner.finish() }
        unrelatedAdmission = nil
        let result = await consumer.value
        #expect(result.exitCode == (finishEarly ? -1 : 0))
        owner.finish()
        let reopened = ModelContext(h.container)
        let saved = try #require(try store.read(taskID: source.id, taskOwnerID: source.persistentModelID))
        #expect(saved.sessionVerificationPending == finishEarly)
        #expect(saved.resourcesReleased == !finishEarly)
        #expect(saved.canReplace == !finishEarly)
        let claim = try #require(RuntimeNativeSessionOwnership.claim(saved))
        #expect(try RuntimeResourceOwnership.claims(in: store, context: reopened).contains(claim) == finishEarly)
    }

    @Test("A provider reporting an occupied session is stopped and cannot supply cleanup proof")
    func reportedConflictStopsProcess() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .codexCLI, in: h)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: source, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        try owner.prepareLaunch(sessionID: "occupied")
        let other = try task("other", runtime: .codexCLI, in: h)
        let contender = try #require(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60))
        defer { contender.finish() }
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.configureExecutionOwner(contender)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .codexCLI, executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"occupied\"}'; exec sleep 10"],
            currentDirectory: other.workspace!.primaryPath, environment: [:], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: true)
        let result = await runner.runRuntimeProcess(adapter: NativeSessionFixtureAdapter(plan: plan), prompt: "Synthetic",
            task: other, workspacePath: other.workspace!.primaryPath, executablePath: "/bin/sh",
            homeDirectory: h.rootURL.path, permissionPolicy: .restricted, timeoutSeconds: 20,
            maxRunSeconds: 20, onLine: { _, _ in })
        #expect(result.runtimeStopReason == "runtime_recovery_blocked")
        #expect(result.runtimeStopMessage?.contains(String(source.id.uuidString.prefix(8))) == true)
        #expect(result.executionStopProof?.toolsStopped == false)
        #expect(contender.record.inheritedToolUncertainty == true)
        #expect(!contender.record.canReplace)
        #expect(contender.record.providerProcess?.presence == .absent)
        #expect(owner.record.sessionID == "occupied")
    }

    @Test("A new model releases only the earlier session with complete protected stop proof", arguments: [false, true])
    func newModelDoesNotReclaimReleasedSession(uncertainFirst: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let source = try task("source", runtime: .claudeCode, in: h)
        source.model = "claude-sonnet-4-6"
        func script(session: String, uncertain: Bool) -> String {
            HeadlessChatScenarioTests.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"\(session)","model":"\(source.model)"}'
            \(uncertain ? "printf '%s\\n' '{\"type\":\"future_signal\"}'" : "")
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Preserved answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Preserved answer","usage":{"input_tokens":3,"output_tokens":5}}'
            """)
        }
        let executable = try h.writeExecutable(named: "claude", script: script(session: "earlier", uncertain: uncertainFirst))
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: executable, permissionPolicy: .autonomous,
            sandboxEnforcementOverride: .off)
        _ = await h.execute(task: source, worker: worker)
        let earlier = try #require(try RuntimeExecutionOwner.existing(task: source, context: h.context))
        #expect(source.status == .completed)
        #expect(earlier.resourcesReleased == !uncertainFirst)
        #expect(earlier.canReplace == !uncertainFirst)

        source.model = "claude-opus-5" // changes the real launch signature, so the next turn creates S2
        _ = try h.writeExecutable(named: "claude", script: script(session: "later", uncertain: true))
        _ = await h.continueTask(task: source, message: "Continue with the new model", worker: worker)
        let later = try #require(try RuntimeExecutionOwner.existing(task: source, context: h.context))
        #expect(source.status == .completed && source.runs.count == 2)
        #expect(later.sessionID == "later" && later.resourcesReleased == false)
        #expect(later.retainedExecutionHead == earlier.executionID)
        let reopened = ModelContext(h.container)
        let held = try RuntimeResourceOwnership.claims(in: RuntimeExecutionOwner.store(in: reopened), context: reopened)
        let earlierClaim = try #require(RuntimeNativeSessionOwnership.claim(runtime: "claude_code", sessionID: "earlier", taskID: UUID()))
        let laterClaim = try #require(RuntimeNativeSessionOwnership.claim(runtime: "claude_code", sessionID: "later", taskID: UUID()))
        #expect(TaskExecutionResourceBroker.canAcquire([earlierClaim], active: held) == !uncertainFirst)
        #expect(!TaskExecutionResourceBroker.canAcquire([laterClaim], active: held))
        let other = try task("independent", runtime: .claudeCode, in: h)
        let independent = try #require(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60))
        defer { independent.finish() }
        if uncertainFirst {
            #expect(throws: (any Error).self) { try independent.prepareLaunch(sessionID: "earlier") }
        } else { try independent.prepareLaunch(sessionID: "earlier") }
    }

    private func signature(for task: AgentTask, run: TaskRun, in context: ModelContext) -> ProviderLaunchSignaturePayload {
        let snapshot = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "")
        let requirements = TaskRuntimeRequirementSet.derive(task: task, capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host, browserBridgeRequired: false)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(task: task, run: run,
            runtime: .codexCLI, model: "default", workspacePath: task.workspace!.primaryPath, phase: .run,
            permissionPolicy: .restricted, executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            runtimeCapabilityProfile: .defaultProfile(for: .codexCLI), capabilityPackages: [], contextText: "",
            precomputedRuntimeRequirements: requirements, modelContext: context)
        let plan = TaskLaunchResourceResolver.resolve(task: task, runID: run.id, runtime: .codexCLI, phase: .run,
            prompt: "", contextText: "", workspacePath: task.workspace!.primaryPath, executionEnvironment: .host)
        return ProviderLaunchSignatureService.make(for: task, manifest: manifest, contextText: "",
            capabilityResolutionSnapshot: snapshot, launchResourcePlan: plan)
    }
}

private struct NativeSessionFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let plan: AgentRuntimeProcessLaunchPlan
    var id: AgentRuntimeID { plan.runtime }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan { plan }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        CodexCLIRuntimeAdapter().parseProcessEvents(line: line, parsesJSONLines: parsesJSONLines)
    }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
