import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Bounded provider preparation", .serialized)
@MainActor
struct RuntimeLaunchWaitTests {
    @Test("Both the actor queue and the kernel lock expire without releasing another holder", arguments: [false, true])
    func deadlinePreservesHolder(kernel: Bool) async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let root = h.rootURL.appendingPathComponent("locks")
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: h.rootURL.path)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        var processLock: ProviderSharedStateProcessLock?
        var local: AgentRuntimeSharedStateLease?
        if kernel { processLock = try await ProviderSharedStateProcessLock.acquire(key, root: root) }
        else { local = try await gate.acquire(key) }
        defer { withExtendedLifetime(processLock) {} }
        // Measure the gate's completion off the UI actor. Other suites may be
        // doing synchronous history reads there after this deadline fires.
        let outcome = try await Task.detached {
            let started = ContinuousClock.now
            do {
                let unexpected = try await gate.acquire(key, timeoutSeconds: 0.05)
                await gate.release(unexpected)
                return (expired: false, elapsed: started.duration(to: .now))
            } catch is RuntimeProviderStateWaitTimeout {
                return (expired: true, elapsed: started.duration(to: .now))
            }
        }.value
        #expect(outcome.expired)
        #expect(outcome.elapsed < .seconds(2))
        if let local { #expect(await gate.isHeld(local)); await gate.release(local) }
        processLock = nil
        let next = try await gate.acquire(key)
        #expect(await gate.release(next))
    }

    @Test("Stop removes a queued waiter and its deadline cannot free the next holder")
    func cancelledWaiter() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("locks"), registeredStoreRoots: [])
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: h.rootURL.path)
        try await Task.detached {
            let first = try await gate.acquire(key)
            let enqueueDeadline = ContinuousClock.now.advanced(by: .seconds(1.1))
            let waiting = Task { try await gate.acquire(key, timeoutSeconds: 1) }
            defer { waiting.cancel() }
            while await gate.queuedWaiterCount(for: key) == 0, ContinuousClock.now < enqueueDeadline {
                await Task.yield()
            }
            #expect(await gate.queuedWaiterCount(for: key) == 1)
            let timerExpired = ContinuousClock.now.advanced(by: .seconds(1.1))
            waiting.cancel()
            do { _ = try await waiting.value; Issue.record("Cancelled wait acquired the gate") }
            catch is CancellationError {}
            #expect(await gate.isHeld(first))
            await gate.release(first)
            // The successor's protected handoff uses the UI actor. Keep the
            // production allowance here so unrelated history reads do not
            // turn this cancellation test into an actor scheduling deadline.
            let next = try await gate.acquire(key)
            // Cross the retired waiter's original deadline while the successor owns
            // the gate; a late timer must never release this different lease.
            try await ContinuousClock().sleep(until: timerExpired)
            #expect(await gate.isHeld(next))
            await gate.release(next)
        }.value
    }

    @Test("A runner deadline pauses before planning or launching and preserves its explanation")
    func runnerDeadline() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        task.status = .running
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 0.1))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: h.rootURL.appendingPathComponent("settings.json").path)
        let lock = try await ProviderSharedStateProcessLock.acquire(key)
        defer { withExtendedLifetime(lock) {} }
        let plans = AgentLockedBuffer()
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.providerStateWaitTimeoutSeconds = 1 // The remaining overall budget is shorter.
        runner.configureExecutionOwner(owner); defer { runner.configureExecutionOwner(nil) }
        let result = await runner.runRuntimeProcess(adapter: DeadlineFixtureAdapter(key: key, plans: plans),
            prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path, executablePath: "/usr/bin/false",
            homeDirectory: h.rootURL.path, permissionPolicy: .restricted, timeoutSeconds: 10, maxRunSeconds: 60,
            onLine: { _, _ in Issue.record("Provider unexpectedly emitted output") })
        #expect(result.runtimeStopReason == RuntimeProviderStateWaitTimeout.stopReason)
        #expect(plans.value.isEmpty && owner.record.providerProcess == nil)
        #expect(owner.record.limits.secondsRemaining == 0)
        #expect(owner.record.preparationStage == "waiting_for_provider")
        #expect(RuntimeStopOutcome.apply(result, task: task, run: run, modelContext: h.context, phase: .run))
        owner.finish(); try h.context.save()
        #expect(task.status == .pendingUser && run.status == .failed)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
        #expect(RuntimeLaunchPresentation.terminalDetail(run: .init(input: .init(run: run)),
            events: task.events.map(TaskEventSnapshot.init(event:)))?.title == "Provider did not start")
    }

    @Test("A joined cancellation before launch replaces the stopping notice with its actual outcome")
    func cancellationNotice() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        owner.requestCancellation()
        try owner.beginSettlement(); try owner.completeSettlement(localWorkStopped: true, toolsStopped: true)
        run.status = .cancelled; run.typedStopReason = .cancelled; run.completedAt = Date()
        owner.finish()
        let message = task.events.filter { $0.type == TaskEventTypes.System.info.rawValue }
            .max { $0.timestamp < $1.timestamp }?.payload
        #expect(message?.contains("cancelled before the provider started") == true)
        #expect(owner.record.state == .notStarted && owner.record.resourcesReleased == true)
    }

    @Test("Preparation and provider execution have separate labels; other runs cannot replace their facts")
    func presentation() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let now = Date(timeIntervalSince1970: 10_000)
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        let run = TaskRun(task: task); h.context.insert(run); run.startedAt = now.addingTimeInterval(-90)
        let waiting = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"preparing\",\"preparationStage\":\"waiting_for_provider\",\"preparationResource\":\"antigravity_cli:settings.json\"}", run: run)
        h.context.insert(waiting)
        let events = [TaskEventSnapshot(event: waiting)]
        let snap = TaskRunSnapshot(input: .init(run: run))
        #expect(RuntimeLaunchPresentation.preparation(for: snap, events: events)?.state == .waitingForResource)
        #expect(RuntimeLaunchPresentation.statusLabel(run: snap, events: events) == "Waiting for resource")
        let other = TaskRun(task: task); h.context.insert(other)
        let unrelated = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"working\"}", run: other)
        unrelated.timestamp = waiting.timestamp.addingTimeInterval(10)
        #expect(RuntimeLaunchPresentation.preparation(for: snap, events: events + [.init(event: unrelated)])?.state == .waitingForResource)
        #expect(RuntimeLaunchPresentation.durationLabel(run: snap, events: events, now: now, format: { "\($0)s" }) == "Waiting for provider configuration · 90s")
        let health = TaskRuntimeHealth.evaluate(taskStatus: .running,
            snapshot: TaskThreadSnapshot(goal: task.goal, createdAt: run.startedAt, events: [waiting], runs: [run]), now: now)
        #expect(health.state == .waitingForResource && health.message == "Waiting for provider configuration")
        run.status = .cancelled; run.completedAt = now
        #expect(RuntimeLaunchPresentation.durationLabel(run: TaskRunSnapshot(input: .init(run: run)), events: events, now: now, format: { "\($0)s" }) == "Elapsed 90s · stopping preparation")
        run.status = .completed
        let started = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: "{\"state\":\"working\",\"providerProcess\":{\"startedSeconds\":9940}}", run: run)
        started.timestamp = waiting.timestamp.addingTimeInterval(1)
        #expect(RuntimeLaunchPresentation.durationLabel(run: TaskRunSnapshot(input: .init(run: run)), events: events + [.init(event: started)], now: now, format: { "\($0)s" }) == "Ran for 60s · preparation 30s")
        #expect(RuntimeLaunchPresentation.durationLabel(run: TaskRunSnapshot(input: .init(run: run)), events: [], now: now, format: { "\($0)s" }) == "Elapsed 90s")
    }
}

private struct DeadlineFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let key: AgentRuntimeSharedStateKey
    let plans: AgentLockedBuffer
    var id: AgentRuntimeID { .antigravityCLI }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func sharedLaunchStateKey(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey? { key }
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        plans.append("unexpected plan")
        return .init(runtime: id, executablePath: "/usr/bin/false", arguments: [], currentDirectory: context.workspacePath,
            environment: [:], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true)
    }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { [] }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
