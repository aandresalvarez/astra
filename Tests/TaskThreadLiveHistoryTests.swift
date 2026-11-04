import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

// Cache-hit assertions need a working set below the process-wide 12-entry LRU.
// Explicit gates still exercise read/build races; other suites run concurrently.
@Suite("Bounded live task history", .serialized)
@MainActor
struct TaskThreadLiveHistoryTests {
    private func fixture() throws -> (ModelContainer, ModelContext, AgentTask, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("history.store"))
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        let task = AgentTask(title: "Synthetic live chat", goal: "Retain durable evidence")
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.status = .running
        context.insert(task)
        return (container, context, task, root)
    }

    @discardableResult
    private func append(_ index: Int, task: AgentTask, context: ModelContext,
                        type: String = "user.message", run: TaskRun? = nil) -> TaskEvent {
        let event = TaskEvent(task: task, type: type, payload: "synthetic \(index)", run: run)
        event.timestamp = Date(timeIntervalSince1970: Double(index + 10))
        context.insert(event)
        return event
    }

    @Test("Thousands of live appends stay bounded across tail, overflow and invalidation")
    func incrementalDiskBackedStream() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        let run = TaskRun(task: task)
        run.status = .running
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        let plan = append(0, task: task, context: context, type: "astra.todo.replace", run: run)
        let permission = append(1, task: task, context: context, type: "permission.approval.requested", run: run)
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        for batch in 0..<60 {
            for offset in 0..<40 { append(2 + batch * 40 + offset, task: task, context: context) }
            run.setOutput("live batch \(batch)")
            vm.refreshSnapshot(for: task)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.retainedHistoryEventCountForTesting <= TaskThreadHistoryPagePolicy.eventCount)
            #expect(vm.snapshot?.sortedEvents.count ?? 0 <= TaskThreadHistoryPagePolicy.eventCount + 2)
            #expect(vm.snapshot?.conversationItems.count ?? 0 <= TaskThreadHistoryPagePolicy.eventCount + 2)
            #expect(vm.snapshot?.latestRun?.output == "live batch \(batch)")
            #expect(vm.snapshot?.sortedEvents.contains { $0.id == plan.id } == true)
            #expect(vm.snapshot?.sortedEvents.contains { $0.id == permission.id } == true)
        }
        #expect(vm.historyTailReadCountForTesting >= 59)
        // Overflow and announced same-count replacement must not re-fetch an
        // ever-growing covering window, or resurrect the removed rows.
        for i in 2_402..<2_902 { append(i, task: task, context: context) }
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        permission.payload = "updated durable permission"
        TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
        task.updatedAt = Date()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(vm.snapshot?.sortedEvents.first { $0.id == permission.id }?.payload == "updated durable permission")
        #expect(vm.hasEarlierHistory)
        // This is a new disk context, not the writer's relationship cache.
        let persisted = ModelContext(container)
        #expect(try persisted.fetchCount(FetchDescriptor<TaskEvent>()) == 2_902)
        let oldest = try persisted.fetch(FetchDescriptor<TaskEvent>(sortBy: [SortDescriptor(\TaskEvent.timestamp)])).first
        #expect(oldest?.id == plan.id)
    }

    @Test("Reading older rows pins their identities while live runs and anchors refresh")
    func browsingAndJumpToLatest() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        for i in 0..<950 { append(i, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let scrollAnchor = try #require(vm.snapshot?.conversationItems.first?.id)
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 600)
        let heldIDs = Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])
        let heldItems = vm.snapshot?.conversationItems.map(\.id) ?? []
        #expect(heldItems.contains(scrollAnchor))
        for batch in 0..<25 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(2_000 + batch))
            run.status = .running
            context.insert(run)
            append(2_000 + batch, task: task, context: context, type: "permission.approval.requested", run: run)
            for offset in 0..<40 { append(3_000 + batch * 40 + offset, task: task, context: context) }
            vm.refreshSnapshot(for: task)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.retainedHistoryEventCountForTesting == 600)
            #expect(vm.retainedHistoryRunCountForTesting <= 12)
            #expect(vm.snapshot?.latestRun?.id == run.id)
            #expect(vm.snapshot?.sortedEvents.contains { $0.runID == run.id && $0.type == "permission.approval.requested" } == true)
            #expect(vm.snapshot?.conversationItems.filter { heldItems.contains($0.id) }.map(\.id) == heldItems)
        }
        #expect(vm.hasNewerHistory)
        // Refresh a replaced anchor and remove one ordinary held row without
        // changing the total. Surviving row order/scroll identities must stay.
        let removedID = try #require(heldIDs.first)
        let removed = try #require(try context.fetch(FetchDescriptor<TaskEvent>()).first { $0.id == removedID })
        context.delete(removed)
        append(-1, task: task, context: context, type: "astra.todo.replace")
        TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 599)
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == removedID } == false)
        // Earlier cursor is still before the same historical boundary; live
        // appends cannot skip the 350 older messages that precede it.
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        let retainedIDs = Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])
        #expect(retainedIDs.isSuperset(of: heldIDs.subtracting([removedID])))
        #expect(vm.retainedHistoryEventCountForTesting == 950) // 949 originals + backdated anchor
        #expect(!vm.hasEarlierHistory)
        vm.followLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(vm.retainedHistoryRunCountForTesting == 12)
        #expect(!vm.hasNewerHistory)
        #expect(vm.hasEarlierHistory)
        append(5_000, task: task, context: context)
        TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(vm.snapshot?.sortedEvents.last?.payload == "synthetic 5000")
    }

    @Test("Publication decision requests and receipts outlive the conversation window")
    func publicationDecisionAnchors() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        let request = append(0, task: task, context: context, type: "git.publish.requested", run: run)
        request.payload = TaskEvent.payloadString(TaskRequiredExternalOutcomeRequest(
            kind: .githubPullRequest, runID: run.id, message: "Review the synthetic publication"
        ))
        for i in 1..<401 { append(i, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        func pendingRequest() -> TaskRequiredExternalOutcomeRequest? {
            let records = (vm.snapshot?.sortedEvents ?? []).map {
                TaskOutcomeEventRecord(id: $0.id, runID: $0.runID, type: $0.type,
                                       payload: $0.payload, timestamp: $0.timestamp)
            }
            return TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
                task: task, targetRunID: run.id, events: records
            )
        }
        #expect(pendingRequest()?.sourceEventID == request.id)
        let receipt = append(401, task: task, context: context, type: "git.publish.receipt", run: run)
        for i in 402..<802 { append(i, task: task, context: context) }
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == receipt.id } == true)
        #expect(pendingRequest() == nil)
    }

    @Test("Publication failures stay actionable after eviction and receipts clear the decision",
          arguments: ["durable", "legacyMessage", "legacyUse"], ["sameRun", "runless", "olderRun"])
    func publicationFailuresSurviveEviction(failureKind: String, receiptScope: String) async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.goal = "Fix the bug and create a pull request"
        task.status = .pendingUser
        var receiptRun: TaskRun?
        if receiptScope == "olderRun" {
            for index in 0..<15 {
                let older = TaskRun(task: task)
                older.startedAt = Date(timeIntervalSince1970: Double(-100 + index))
                context.insert(older)
                if index == 0 { receiptRun = older }
            }
        }
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .failed
        run.stopReason = TaskRunStopReason.externalOutcomePending.rawValue
        context.insert(run)
        if receiptScope == "sameRun" { receiptRun = run }
        if failureKind == "legacyUse" {
            let use = append(-1, task: task, context: context, type: "tool.use", run: run)
            use.payload = "bash: gh pr create --draft"
        }
        let failure = append(0, task: task, context: context,
                             type: failureKind == "durable" ? "git.publish.failed" : "tool.result.failed", run: run)
        if failureKind == "durable" {
            failure.payload = TaskEvent.payloadString(TaskRequiredExternalOutcomeFailure(
                version: 1, kind: .githubPullRequest, runID: run.id,
                sourceEventID: nil, message: "gh pr create failed"
            ))
        } else if failureKind == "legacyMessage" {
            failure.payload = TaskEvent.payloadString(ToolResultFailurePayload(
                toolID: "bash", message: "gh pr create: permission denied"
            ))
        } else {
            failure.payload = "permission denied"
        }
        // A later unrelated tool failure and a malformed durable failure must
        // not replace the still-unresolved publication evidence.
        let otherUse = append(40, task: task, context: context, type: "tool.use", run: run)
        otherUse.payload = "git status"
        let otherFailure = append(41, task: task, context: context, type: "tool.result.failed", run: run)
        otherFailure.payload = "unrelated command failed"
        append(42, task: task, context: context, type: "git.publish.failed", run: run)
        let receipt = append(-10, task: task, context: context, type: "git.publish.receipt", run: receiptRun)
        receipt.payload = "{}"
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        func durablePending() -> Bool {
            TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) != nil
        }
        func dockPending() -> Bool {
            TaskDecisionOutcomeResolver.outcomes(
                task: task, snapshot: vm.snapshot, decisionArtifactPaths: [], modelContext: context
            ).hasGitPublishRequest
        }
        #expect(durablePending())
        #expect(dockPending() == durablePending())
        for batch in 0..<20 {
            for offset in 0..<20 { append(100 + batch * 20 + offset, task: task, context: context) }
            vm.refreshSnapshot(for: task)
            await vm.waitForPendingWorkForTesting()
        }
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == failure.id } == false)
        #expect(durablePending())
        #expect(dockPending() == durablePending())
        #expect((vm.snapshot?.decisionOutcomeInputs.events ?? []).filter {
            $0.type.hasPrefix("git.publish.") || $0.type == "tool.use" || $0.type == "tool.result.failed"
        }.count <= 6)
        #expect(vm.snapshot?.decisionOutcomeInputs.events.count ?? 0 <= 306)
        #expect(TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: task.status, latestRunStopReason: .externalOutcomePending, hasPendingPublication: dockPending()
        ))
        // Move an existing receipt forward, including one attached to a run
        // outside the 12-run transcript window, then evict its ordinary row.
        receipt.timestamp = Date(timeIntervalSince1970: 1_000)
        task.updatedAt = Date()
        TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(!durablePending())
        #expect(dockPending() == durablePending())
        for index in 2_000..<2_400 { append(index, task: task, context: context) }
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(dockPending() == durablePending())
        #expect(!dockPending())
        #expect(!TaskGitPullRequestPublishReviewPolicy.shouldOffer(
            taskStatus: task.status, latestRunStopReason: .externalOutcomePending, hasPendingPublication: dockPending()
        ))
        #expect((vm.snapshot?.decisionOutcomeInputs.events ?? []).filter {
            $0.type.hasPrefix("git.publish.") || $0.type == "tool.use" || $0.type == "tool.result.failed"
        }.count <= 6)
        #expect(vm.snapshot?.decisionOutcomeInputs.events.count ?? 0 <= 306)
        #expect(vm.retainedHistoryEventCountForTesting == 300)
    }

    @Test("Legacy evidence search crosses bounded batches and isolates imported task owners")
    func legacyEvidenceSearchIsBatchedAndOwnerScoped() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.goal = "Fix the bug and create a pull request"
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        context.insert(run)
        let use = append(0, task: task, context: context, type: "tool.use", run: run)
        use.payload = "gh pr create --draft"
        let failed = append(1, task: task, context: context, type: "tool.result.failed", run: run)
        failed.payload = "permission denied"
        let otherUse = append(2, task: task, context: context, type: "tool.use", run: run)
        otherUse.payload = "git status"
        for index in 3..<143 {
            let unrelated = append(index, task: task, context: context, type: "tool.result.failed", run: run)
            unrelated.payload = "unrelated command failed"
        }
        for index in 200..<600 { append(index, task: task, context: context) }
        let imported = AgentTask(title: "Other owner", goal: "Synthetic imported copy")
        imported.id = task.id
        context.insert(imported)
        append(10_000, task: imported, context: context, type: "git.publish.receipt")
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let metadata = (vm.snapshot?.decisionOutcomeInputs.events ?? []).filter {
            $0.type == "tool.use" || $0.type == "tool.result.failed" || $0.type.hasPrefix("git.publish.")
        }
        #expect(metadata.count == 2)
        #expect(Set(metadata.map(\.id)) == Set([use.id, failed.id]))
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(TaskDecisionOutcomeResolver.outcomes(
            task: task, snapshot: vm.snapshot, decisionArtifactPaths: [], modelContext: context
        ).hasGitPublishRequest)
    }

    @Test("Streaming runs evict old run snapshots and their state anchors")
    func runAndAnchorRetention() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        for index in 0..<40 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(index))
            run.status = .running
            context.insert(run)
            append(index, task: task, context: context, type: "permission.approval.requested", run: run)
            vm.refreshSnapshot(for: task)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.retainedHistoryRunCountForTesting <= 12)
            #expect(vm.retainedHistoryAnchorCountForTesting <= 12)
            #expect(vm.snapshot?.latestRun?.id == run.id)
        }
        let visibleRuns = Set(vm.snapshot?.sortedRuns.map(\.id) ?? [])
        #expect(vm.snapshot?.sortedEvents.allSatisfy { $0.runID.map(visibleRuns.contains) ?? true } == true)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskRun>()) == 40)
        // Total runs can shrink while still exceeding the 12 retained runs.
        // Comparing against the visible count would strand this deleted run.
        let deletedID = try #require(vm.snapshot?.latestRun?.id)
        let deletedRun = try #require(try context.fetch(FetchDescriptor<TaskRun>()).first { $0.id == deletedID })
        let fullReads = vm.historyFullReadCountForTesting
        // TaskEvent.run is unidirectional; keep the fixture valid rather than
        // leaving a dangling SwiftData relationship to an invalidated model.
        for event in try context.fetch(FetchDescriptor<TaskEvent>()) where event.run?.id == deletedID {
            event.run = nil
        }
        context.delete(deletedRun)
        task.updatedAt = Date()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.historyFullReadCountForTesting == fullReads + 1)
        #expect(vm.snapshot?.sortedRuns.contains { $0.id == deletedID } == false)
        #expect(vm.retainedHistoryRunCountForTesting == 12)
    }

    @Test("Pausing an already-building snapshot preserves the rows still on screen")
    func pauseDuringSnapshotBuild() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        let run = TaskRun(task: task)
        run.status = .running
        run.setOutput("initial output")
        context.insert(run)
        for i in 0..<300 { append(i, task: task, context: context) }
        try context.save()
        let gate = LiveHistoryBuildGate()
        let vm = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            await gate.enter()
            return TaskThreadSnapshot(input: input)
        })
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let displayedIDs = Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])
        await gate.arm()
        task.status = .completed
        task.updatedAt = Date()
        run.status = .completed
        run.setOutput("FINAL output")
        append(300, task: task, context: context)
        vm.refreshSnapshot(for: task)
        await gate.waitUntilParked()
        // The read has evicted event 0, but the UI still displays it.
        vm.pauseFollowingLatestHistory(for: task)
        await gate.release()
        await vm.waitForPendingWorkForTesting()
        let retainedIDs = Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])
        #expect(retainedIDs.isSuperset(of: displayedIDs))
        #expect(vm.retainedHistoryEventCountForTesting == 301)
        #expect(vm.hasNewerHistory)
        #expect(vm.snapshot?.latestRun?.status == .completed)
        #expect(vm.snapshot?.latestRun?.output == "FINAL output")
        task.status = .completed
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        // A browsed terminal snapshot cannot poison the default-window cache.
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
    }

    @Test("Rolling equal-count rows still follow layout while a real user scroll pins history")
    func rollingRowsHaveDistinctScrollRevisions() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        let run = TaskRun(task: task)
        run.status = .running
        run.setOutput("unchanged unfinished output")
        context.insert(run)
        for index in 0..<300 { append(index, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let before = try #require(vm.snapshot)
        let beforeRevision = vm.appliedSnapshotReadiness
        let follow = TaskChatFollowLayoutState()
        follow.noteSnapshotHandled(beforeRevision)
        let replacement = append(300, task: task, context: context)
        replacement.payload = String(repeating: "taller replacement ", count: 100)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        let after = try #require(vm.snapshot)
        #expect(after.conversationItems.count == before.conversationItems.count)
        #expect(after.conversationItems.last?.id == before.conversationItems.last?.id)
        #expect(after.latestRun?.output == before.latestRun?.output)
        #expect(after.latestRun?.status == before.latestRun?.status)
        let revision = vm.appliedSnapshotReadiness
        #expect(revision != beforeRevision)
        // The view consumes this source revision, including geometry delivered
        // before its deferred onChange callback has armed the double follow.
        #expect(follow.shouldDeferBottomChange(isFollowing: true, snapshot: revision))
        follow.noteSnapshotHandled(revision)
        let pending = follow.beginFollow(snapshot: revision)
        let token = try #require(pending)
        #expect(follow.shouldDeferBottomChange(isFollowing: true, snapshot: revision))
        follow.finish(token)
        let next = append(301, task: task, context: context)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == next.id } == true)
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        follow.noteUserScroll(snapshot: vm.appliedSnapshotReadiness)
        #expect(!follow.shouldDeferBottomChange(isFollowing: true, snapshot: vm.appliedSnapshotReadiness))
        vm.pauseFollowingLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        let waiting = append(302, task: task, context: context)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.hasNewerHistory)
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == waiting.id } == false)
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == next.id } == true)
        vm.followLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == waiting.id } == true)
    }

    @Test("An idle scroll pause changes layout readiness without reporting new content")
    func pauseDoesNotReportUnseenContent() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        let run = TaskRun(task: task)
        run.status = .running
        run.setOutput("initial output")
        context.insert(run)
        let message = append(0, task: task, context: context)
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        let before = vm.appliedSnapshotReadiness
        vm.pauseFollowingLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        let paused = vm.appliedSnapshotReadiness
        #expect(paused.revision > before.revision)
        #expect(!paused.hasContentChange(from: before))
        #expect(!vm.hasNewerHistory)

        // Same-size edits and run output changes still count while browsing.
        message.payload = "edited message"
        task.updatedAt = Date()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        let edited = vm.appliedSnapshotReadiness
        #expect(edited.hasContentChange(from: paused))
        #expect(!vm.hasNewerHistory)
        run.setOutput("changed output")
        task.updatedAt = Date()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        let output = vm.appliedSnapshotReadiness
        #expect(output.hasContentChange(from: edited))

        let pending = append(1, task: task, context: context)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.hasNewerHistory)
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == pending.id } == false)
    }

    @Test("A cached state-only page keeps the storage boundary ahead of older messages and anchors")
    func cacheHitPagesStateOnlyLatestWindow() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(run)
        let receipt = append(-100, task: task, context: context, type: "git.publish.receipt", run: run)
        receipt.payload = #"{"pullRequestNumber":1,"pullRequestURL":"https://github.com/acme/widgets/pull/1","isDraft":true}"#
        let messages = (0..<60).map { append($0, task: task, context: context).id }
        for index in 1_000..<1_300 {
            append(index, task: task, context: context, type: "astra.todo.replace", run: run)
        }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.lastSnapshotCacheState == "hit")
        #expect(vm.hasEarlierHistory)
        #expect(vm.snapshot?.sortedEvents.contains { $0.type == "user.message" } == false)
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        let displayed = Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])
        #expect(Set(messages).isSubset(of: displayed))
        #expect(!vm.hasEarlierHistory)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskEvent>()) == 361)
    }

    @Test("Browsing a cache hit keeps both displayed receipts without moving its paging boundary")
    func cacheHitKeepsDisplayedReceiptsWhileBrowsing() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(run)
        let messages = (0..<340).map { append($0, task: task, context: context).id }
        let receipts = [340, 341].map { index in
            let event = append(index, task: task, context: context, type: "git.publish.receipt", run: run)
            event.payload = #"{"pullRequestNumber":1,"pullRequestURL":"https://github.com/acme/widgets/pull/1","isDraft":true}"#
            return event
        }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.lastSnapshotCacheState == "hit")
        let recordIDs: () -> Set<UUID> = {
            Set(vm.snapshot?.conversationItems.compactMap { item in
                if case .externalAction(let record) = item { return record.id }
                return nil
            } ?? [])
        }
        #expect(recordIDs() == Set(receipts.map(\.id)))
        vm.pauseFollowingLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(recordIDs() == Set(receipts.map(\.id)))
        receipts[0].payload = #"{"pullRequestNumber":2,"pullRequestURL":"https://github.com/acme/widgets/pull/2","isDraft":true}"#
        try context.save()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.snapshot?.sortedEvents.first { $0.id == receipts[0].id }?.payload == receipts[0].payload)
        context.delete(receipts[0])
        try context.save()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(recordIDs() == [receipts[1].id])
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(Set(messages).isSubset(of: Set(vm.snapshot?.sortedEvents.map(\.id) ?? [])))
        #expect(!vm.hasEarlierHistory)
    }

    @Test("A cached terminal transcript keeps its pinned anchor when activity resumes", arguments: [false, true])
    func cacheHitPinsDisplayedRows(earlierWithNewActivity: Bool) async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        run.setOutput("cached final output")
        context.insert(run)
        for index in 0..<340 { append(index, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.lastSnapshotCacheState == "hit")
        if earlierWithNewActivity {
            let anchor = try #require(vm.snapshot?.sortedEvents.first?.id)
            task.status = .running
            task.updatedAt = Date()
            run.status = .running
            for index in 340..<740 { append(index, task: task, context: context) }
            try context.save()
            vm.loadEarlierHistory(for: task)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.snapshot?.sortedEvents.contains { $0.id == anchor } == true)
            #expect(vm.snapshot?.latestRun?.id == run.id)
            #expect(vm.snapshot?.latestRun?.status == .running)
            #expect(vm.retainedHistoryEventCountForTesting == 340)
            #expect(vm.hasNewerHistory && !vm.hasEarlierHistory)
            vm.followLatestHistory(for: task)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.retainedHistoryEventCountForTesting == 300)
            #expect(!vm.hasNewerHistory)
            return
        }
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 340)
        #expect(vm.snapshot?.latestRun?.id == run.id)
        #expect(vm.snapshot?.latestRun?.output == "cached final output")
        vm.followLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.lastSnapshotCacheState == "hit")
        let anchor = try #require(vm.snapshot?.sortedEvents.first?.id)
        vm.pauseFollowingLatestHistory(for: task)
        task.status = .running
        task.updatedAt = Date()
        run.status = .running
        for index in 340..<740 { append(index, task: task, context: context) }
        try context.save()
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.snapshot?.sortedEvents.contains { $0.id == anchor } == true)
        #expect(vm.hasNewerHistory)
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        vm.loadEarlierHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(!vm.hasEarlierHistory && vm.hasNewerHistory)
        #expect(vm.retainedHistoryEventCountForTesting == 340)
        vm.followLatestHistory(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(!vm.hasNewerHistory)
    }

    @Test("Committed same-count publication edits reach live and cached terminal decisions", arguments: [false, true])
    func savedEvidenceRefreshesTheDecision(terminal: Bool) async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.goal = "Fix the bug and create a pull request"
        task.status = terminal ? .completed : .running
        let run = TaskRun(task: task)
        run.status = terminal ? .completed : .running
        context.insert(run)
        let failed = append(0, task: task, context: context, type: "tool.result.failed", run: run)
        failed.payload = "unrelated command failed"
        for index in 1..<345 { append(index, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        if terminal {
            vm.reset(for: task, modelContext: context)
            await vm.waitForPendingWorkForTesting()
            #expect(vm.lastSnapshotCacheState == "hit")
        }
        func dock() -> Bool {
            TaskDecisionOutcomeResolver.outcomes(task: task, snapshot: vm.snapshot,
                decisionArtifactPaths: [], modelContext: context).hasGitPublishRequest
        }
        #expect(!dock())
        let timestamp = task.updatedAt
        let before = vm.appliedSnapshotRevision
        failed.payload = "gh pr create: permission denied"
        try context.save()
        // No explicit refresh: the real committed-save observer owns delivery.
        await vm.waitForPendingWorkForTesting()
        #expect(task.updatedAt == timestamp)
        #expect(vm.appliedSnapshotRevision > before)
        #expect(dock())
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) != nil)
        #expect(vm.retainedHistoryEventCountForTesting <= 300)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(dock())
        // A same-count resolving edit must also clear the cached decision.
        failed.payload = "unrelated command failed"
        try context.save()
        await vm.waitForPendingWorkForTesting()
        #expect(!dock())
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(!dock())
    }

    @Test("Inactive terminal owners invalidate only their own cached decision", arguments: [false, true])
    func inactiveOwnerDecision(sharedPortableID: Bool) async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.goal = "Fix the bug and create a pull request"
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(run)
        let failed = append(0, task: task, context: context, type: "tool.result.failed", run: run)
        failed.payload = "unrelated command failed"
        for index in 1..<345 { append(index, task: task, context: context) }
        let other = AgentTask(title: "B", goal: "Unrelated")
        other.status = .completed
        if sharedPortableID { other.id = task.id }
        context.insert(other)
        append(0, task: other, context: context)
        try context.save()
        let timestamp = task.updatedAt
        let vm = TaskThreadViewModel()
        func open(_ owner: AgentTask) async {
            vm.reset(for: owner, modelContext: context)
            await vm.waitForPendingWorkForTesting()
        }
        func dock() -> Bool {
            TaskDecisionOutcomeResolver.outcomes(task: task, snapshot: vm.snapshot,
                decisionArtifactPaths: [], modelContext: context).hasGitPublishRequest
        }
        await open(task)
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit" && !dock())
        await open(other)
        // Ordinary appends for B must leave A's cache and evidence cold.
        append(1, task: other, context: context)
        other.updatedAt = Date()
        try context.save()
        vm.refreshSnapshot(for: other)
        await vm.waitForPendingWorkForTesting()
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit")
        #expect(vm.historyReadCountForTesting == 0)
        await open(other)
        #expect(vm.lastSnapshotCacheState == "hit")
        let otherRevision = vm.appliedSnapshotRevision
        failed.payload = "gh pr create: permission denied"
        try context.save()
        await vm.waitForPendingWorkForTesting()
        #expect(vm.appliedSnapshotRevision == otherRevision)
        #expect(vm.historyReadCountForTesting == 0)
        vm.refreshSnapshot(for: other)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.lastSnapshotCacheState == "hit")
        #expect(vm.historyReadCountForTesting == 0)
        await open(task)
        #expect(vm.historyReadCountForTesting > 0)
        #expect(task.updatedAt == timestamp)
        #expect(dock())
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) != nil)
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit" && dock())
        await open(other)
        #expect(vm.lastSnapshotCacheState == "hit")
        failed.payload = "unrelated command failed"
        try context.save()
        await vm.waitForPendingWorkForTesting()
        #expect(vm.historyReadCountForTesting == 0)
        await open(task)
        #expect(vm.historyReadCountForTesting > 0)
        #expect(task.updatedAt == timestamp)
        #expect(!dock())
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) == nil)
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit" && !dock())
    }

    @Test("Backdated tool-use inserts invalidate inactive terminal decisions while later uses stay cached")
    func backdatedToolUseInvalidatesTerminalCache() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.goal = "Fix the bug and create a pull request"
        task.status = .completed
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(run)
        let failure = append(0, task: task, context: context, type: "tool.result.failed", run: run)
        failure.payload = "permission denied"
        for index in 1..<345 { append(index, task: task, context: context) }
        let other = AgentTask(title: "Other", goal: "Unrelated")
        other.status = .completed
        context.insert(other)
        try context.save()
        let timestamp = task.updatedAt
        let vm = TaskThreadViewModel()
        func open(_ owner: AgentTask) async {
            vm.reset(for: owner, modelContext: context)
            await vm.waitForPendingWorkForTesting()
        }
        func pending() -> Bool {
            TaskDecisionOutcomeResolver.outcomes(task: task, snapshot: vm.snapshot,
                decisionArtifactPaths: [], modelContext: context).hasGitPublishRequest
        }
        await open(task)
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit" && !pending())
        await open(other)
        let later = append(1, task: task, context: context, type: "tool.use", run: run)
        later.payload = "gh pr create --draft"
        task.updatedAt = timestamp
        try context.save()
        await open(task)
        #expect(vm.lastSnapshotCacheState == "hit" && !pending())
        #expect(vm.historyReadCountForTesting == 0)
        await open(other)
        let before = append(-1, task: task, context: context, type: "tool.use", run: run)
        before.payload = "gh pr create --draft"
        task.updatedAt = timestamp
        try context.save()
        #expect(task.updatedAt == timestamp)
        await open(task)
        #expect(vm.lastSnapshotCacheState != "hit")
        #expect(vm.historyReadCountForTesting > 0)
        #expect(pending())
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) != nil)
    }

    @Test("Terminal cache observation revisions reject stale values and eviction releases observers")
    func terminalCacheObservationLifetime() throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        task.status = .completed
        let failed = append(0, task: task, context: context, type: "tool.result.failed")
        let other = AgentTask(title: "Other", goal: "Unrelated")
        other.status = .completed
        context.insert(other)
        try context.save()
        let key = try #require(TaskThreadSnapshotCacheKey(task: task, maxRuns: 12))
        let otherKey = try #require(TaskThreadSnapshotCacheKey(task: other, maxRuns: 12))
        let snapshot = TaskThreadSnapshot.placeholder(goal: task.goal, createdAt: task.createdAt)
        var cache = TaskThreadSnapshotCache(maxEntries: 1)
        weak var held: TaskPublicationDecisionEvidenceReader.MutationTracker?
        do {
            let observation = TaskPublicationDecisionEvidenceReader.MutationTracker(container: container,
                ownerID: task.persistentModelID, observeInsertedEvidence: true)
            held = observation
            cache.store(snapshot, for: key, saveObservation: observation, readRevision: observation.revision)
        }
        #expect(held != nil)
        #expect(cache.snapshot(for: key) != nil)
        failed.payload = "gh pr create: permission denied"
        // This is the pre-commit half of a failed/abandoned save. Lookup must
        // reject the old revision immediately, without waiting for didSave.
        NotificationCenter.default.post(name: ModelContext.willSave, object: context)
        #expect(cache.snapshot(for: key) == nil)
        #expect(held == nil)
        context.rollback()
        do {
            let observation = TaskPublicationDecisionEvidenceReader.MutationTracker(container: container,
                ownerID: task.persistentModelID, observeInsertedEvidence: true)
            held = observation
            cache.store(snapshot, for: key, saveObservation: observation, readRevision: observation.revision)
        }
        #expect(held != nil)
        cache.store(snapshot, for: otherKey)
        #expect(cache.stats.entryCount == 1)
        #expect(held == nil)
    }

    @Test("A mode change or older-page merge during a read cannot restore a stale window")
    func modeChangesDuringRead() async throws {
        let (container, context, task, root) = try fixture()
        defer { _ = container; try? FileManager.default.removeItem(at: root) }
        for i in 0..<1_000 { append(i, task: task, context: context) }
        try context.save()
        let vm = TaskThreadViewModel()
        vm.reset(for: task, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        var interleaved = false
        vm.didCaptureHistoryPageForTesting = {
            guard !interleaved else { return }
            interleaved = true
            vm.loadEarlierHistory(for: task)
        }
        append(1_001, task: task, context: context)
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        #expect(interleaved)
        #expect(vm.retainedHistoryEventCountForTesting == 600)
        vm.didCaptureHistoryPageForTesting = nil
        var jumped = false
        vm.didCaptureHistoryPageForTesting = {
            guard !jumped else { return }
            jumped = true
            vm.followLatestHistory(for: task)
        }
        vm.refreshSnapshot(for: task)
        await vm.waitForPendingWorkForTesting()
        vm.didCaptureHistoryPageForTesting = nil
        #expect(jumped)
        #expect(vm.retainedHistoryEventCountForTesting == 300)
        #expect(vm.snapshot?.sortedEvents.last?.payload == "synthetic 1001")
        let second = AgentTask(title: "Other", goal: "Other task")
        context.insert(second)
        append(0, task: second, context: context)
        vm.pauseFollowingLatestHistory(for: task)
        vm.refreshSnapshot(for: task)
        vm.reset(for: second, modelContext: context)
        await vm.waitForPendingWorkForTesting()
        #expect(vm.appliedSnapshotTaskID == second.id)
        #expect(vm.retainedHistoryEventCountForTesting == 1)
        #expect(!vm.hasNewerHistory)
    }
}

private actor LiveHistoryBuildGate {
    private var shouldPark = false
    private var parked: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arm() { shouldPark = true }
    func enter() async {
        guard shouldPark else { return }
        shouldPark = false
        await withCheckedContinuation { continuation in
            parked = continuation
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
    func waitUntilParked() async {
        guard parked == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { parked?.resume(); parked = nil }
}
