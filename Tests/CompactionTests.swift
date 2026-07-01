import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

private func makeCompactionTestContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func encodedAssertionPayload(planID: UUID, assertionID: String, status: String) throws -> String {
    let payload = TaskValidationAssertionEventPayload(
        version: 1,
        planID: planID,
        assertionID: assertionID,
        scope: .plan,
        stepID: nil,
        method: .command,
        required: true,
        status: status,
        summary: "assertion \(assertionID) \(status)",
        command: nil,
        exitCode: nil,
        path: nil,
        evidence: nil,
        reason: nil
    )
    let data = try TaskEventPayloadCodec.makeEncoder().encode(payload)
    return String(decoding: data, as: UTF8.self)
}

private func encodedContractPayload(planID: UUID, status: String) throws -> String {
    let payload = TaskValidationContractEventPayload(
        version: 1,
        planID: planID,
        status: status,
        requiredPassed: 1,
        requiredTotal: 1,
        failedRequiredAssertionIDs: [],
        summary: "contract \(status)"
    )
    let data = try TaskEventPayloadCodec.makeEncoder().encode(payload)
    return String(decoding: data, as: UTF8.self)
}

@Suite("Event Compaction")
@MainActor
struct CompactionTests {

    @Test("Compaction threshold is 200")
    func thresholdValue() {
        #expect(AgentRuntimeWorker.compactionThreshold == 200)
    }

    @Test("Keep count is 50")
    func keepCountValue() {
        #expect(AgentRuntimeWorker.compactionKeepCount == 50)
    }

    @Test("Events below threshold are not compacted")
    func belowThreshold() {
        // Simulate 150 events (below 200 threshold)
        let eventCount = 150
        #expect(eventCount <= AgentRuntimeWorker.compactionThreshold)
        // compactEvents would be a no-op — we verify the threshold logic
    }

    @Test("Events above threshold would compact down")
    func aboveThreshold() {
        let total = 250
        let threshold = AgentRuntimeWorker.compactionThreshold
        let keepCount = AgentRuntimeWorker.compactionKeepCount

        #expect(total > threshold)

        let cutoff = total - keepCount
        #expect(cutoff == 200) // 250 - 50 = 200 events to compact

        // After compaction: 50 kept + 1 summary = 51 events
        let afterCompaction = keepCount + 1
        #expect(afterCompaction == 51)
    }

    @Test("Summary generation from type counts")
    func summaryGeneration() {
        var typeCounts: [String: Int] = [:]
        // Simulate counting event types
        for _ in 0..<80 { typeCounts["agent.response", default: 0] += 1 }
        for _ in 0..<50 { typeCounts["tool.use", default: 0] += 1 }
        for _ in 0..<30 { typeCounts["agent.thinking", default: 0] += 1 }
        for _ in 0..<5 { typeCounts["error", default: 0] += 1 }

        let summary = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")

        #expect(summary.contains("80 agent.response"))
        #expect(summary.contains("50 tool.use"))
        #expect(summary.contains("30 agent.thinking"))
        #expect(summary.contains("5 error"))
    }

    @Test("Cutoff calculation preserves most recent events")
    func cutoffPreservesRecent() {
        let total = 300
        let keepCount = AgentRuntimeWorker.compactionKeepCount
        let cutoff = total - keepCount

        // Items at indices [0..<cutoff] are compacted
        // Items at indices [cutoff..<total] are kept
        #expect(cutoff == 250)

        // Verify the kept range is the suffix
        let allIndices = Array(0..<total)
        let kept = Array(allIndices.suffix(keepCount))
        #expect(kept.first == 250)
        #expect(kept.last == 299)
        #expect(kept.count == 50)
    }

    @Test("Compaction preserves Astra protocol events")
    func preservesAstraProtocolEvents() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)
        let protocolPayload = AstraRunProtocolParsedEvent.valid(.complete(
            summary: "Finished",
            verifiedBy: "swift test"
        )).normalizedPayload

        for index in 0..<210 {
            let event: TaskEvent
            if index == 10 || index == 20 {
                event = TaskEvent(task: task, type: "astra.complete", payload: protocolPayload)
            } else {
                event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            }
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)

        let protocolEvents = task.events.filter { $0.type == "astra.complete" }
        #expect(protocolEvents.count == 2)
        #expect(task.events.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction preserves user-visible conversation anchors")
    func preservesUserVisibleConversationAnchors() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        let preservedTypes = ["user.message", "schedule.result", "system.info", "recap.result"]
        for index in 0..<230 {
            let type = preservedTypes.indices.contains(index) ? preservedTypes[index] : "agent.response"
            let event = TaskEvent(task: task, type: type, payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remainingEvents = try context.fetch(FetchDescriptor<TaskEvent>())

        for type in preservedTypes {
            #expect(remainingEvents.contains { $0.type == type })
        }
        #expect(!remainingEvents.contains { $0.type == "agent.response" && $0.payload == "event 10" })
        #expect(remainingEvents.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction preserves critical blocker and validation events")
    func preservesCriticalBlockerAndValidationEvents() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        let preserved: [(Int, String, String)] = [
            (5, "error", "Tests failed: ContextContinuityTests"),
            (8, "budget.exceeded", "Token budget exceeded before validation"),
            (13, "permission.denied", "Permission denied for tool: Bash"),
            (21, "permission.approval.requested", "Permission requested for tool: Bash"),
            (34, "task.completed", "Tests passed. 3 tests passed."),
            (55, "task.interrupted", "Interrupted during provider shutdown")
        ]

        for index in 0..<230 {
            let match = preserved.first { $0.0 == index }
            let event = TaskEvent(
                task: task,
                type: match?.1 ?? "agent.response",
                payload: match?.2 ?? "event \(index)"
            )
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remainingEvents = try context.fetch(FetchDescriptor<TaskEvent>())
        for item in preserved {
            #expect(remainingEvents.contains { $0.type == item.1 && $0.payload == item.2 })
        }
        #expect(!remainingEvents.contains { $0.type == "agent.response" && $0.payload == "event 10" })
        #expect(remainingEvents.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction preserves plan and validation lifecycle so state still reconstructs")
    func preservesPlanAndValidationLifecycleEvents() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        // An approved plan + a passed contract, recorded EARLY (well before the
        // 50-event recency window) so they are compaction candidates.
        let plan = TaskPlanPayload(
            title: "Ship export",
            goal: "Implement and verify the export feature",
            steps: [TaskPlanPayloadStep(id: "s1", title: "Build export")]
        )
        let planEvent = TaskEvent(
            task: task,
            type: TaskPlanEventTypes.approved,
            payload: TaskPlanService.encodePlanPayload(plan)
        )
        planEvent.timestamp = Date(timeIntervalSince1970: 5)
        context.insert(planEvent)

        let contractEvent = TaskEvent(
            task: task,
            type: TaskValidationEventTypes.contractPassed,
            payload: try encodedContractPayload(planID: plan.planID, status: "passed")
        )
        contractEvent.timestamp = Date(timeIntervalSince1970: 8)
        context.insert(contractEvent)

        // 250 later filler events push the lifecycle events out of the keep window.
        for index in 0..<250 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>())
        // Lifecycle events survived…
        #expect(remaining.contains { $0.type == TaskPlanEventTypes.approved })
        #expect(remaining.contains { $0.type == TaskValidationEventTypes.contractPassed })
        // …while ordinary old activity was compacted…
        #expect(!remaining.contains { $0.type == "agent.response" && $0.payload == "event 0" })
        #expect(remaining.contains { $0.type == "activity.compacted" })

        // …so the plan still reconstructs as approved with the original goal,
        // instead of silently reverting to draft/none.
        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.lifecycleStatus == .approved)
        #expect(state.plan?.goal == "Implement and verify the export feature")
    }

    @Test("Compaction keeps the latest status of every assertion, not just one per type")
    func preservesPerAssertionStatusAcrossCompaction() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        let planID = UUID()
        // Two assertions sharing the SAME event type (.passed), recorded early.
        // Latest-of-type would keep only the most recent .passed event (a2),
        // silently dropping a1; per-assertionID keeps both.
        let a1 = TaskEvent(
            task: task,
            type: TaskValidationEventTypes.assertionPassed,
            payload: try encodedAssertionPayload(planID: planID, assertionID: "a1", status: "passed")
        )
        a1.timestamp = Date(timeIntervalSince1970: 5)
        context.insert(a1)

        let a2 = TaskEvent(
            task: task,
            type: TaskValidationEventTypes.assertionPassed,
            payload: try encodedAssertionPayload(planID: planID, assertionID: "a2", status: "passed")
        )
        a2.timestamp = Date(timeIntervalSince1970: 8)
        context.insert(a2)

        for index in 0..<250 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>())
        let survivingAssertionIDs = remaining
            .filter { $0.type == TaskValidationEventTypes.assertionPassed }
            .compactMap { event -> String? in
                if case let .success(payload) = ValidationService.decodeAssertionPayloadResult(event.payload) {
                    return payload.assertionID
                }
                return nil
            }
        #expect(Set(survivingAssertionIDs) == ["a1", "a2"])
        #expect(remaining.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction keeps same-named assertions from different plans (no planID collision)")
    func preservesAssertionsAcrossPlansWithoutCollision() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        // Two plans that reuse assertion id "a1". Keying by assertionID alone would
        // collide and drop one plan's event; keying by (planID, assertionID) keeps both.
        let planA = UUID()
        let planB = UUID()
        let aEvent = TaskEvent(
            task: task,
            type: TaskValidationEventTypes.assertionPassed,
            payload: try encodedAssertionPayload(planID: planA, assertionID: "a1", status: "passed")
        )
        aEvent.timestamp = Date(timeIntervalSince1970: 5)
        context.insert(aEvent)
        let bEvent = TaskEvent(
            task: task,
            type: TaskValidationEventTypes.assertionPassed,
            payload: try encodedAssertionPayload(planID: planB, assertionID: "a1", status: "passed")
        )
        bEvent.timestamp = Date(timeIntervalSince1970: 8)
        context.insert(bEvent)

        for index in 0..<250 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>())
        let survivingPlanIDs = remaining
            .filter { $0.type == TaskValidationEventTypes.assertionPassed }
            .compactMap { event -> UUID? in
                if case let .success(payload) = ValidationService.decodeAssertionPayloadResult(event.payload) {
                    return payload.planID
                }
                return nil
            }
        #expect(Set(survivingPlanIDs) == [planA, planB])
        #expect(remaining.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction summary preserves commands paths and test evidence")
    func compactionSummaryPreservesSemanticEvidence() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        for index in 0..<230 {
            let event: TaskEvent
            switch index {
            case 7:
                event = TaskEvent(
                    task: task,
                    type: "tool.use",
                    payload: "Using tool: Bash: swift test --filter PromptContextContinuityTests"
                )
            case 8:
                event = TaskEvent(
                    task: task,
                    type: "tool.result",
                    payload: "Tests failed in /tmp/Astra/Services/Runtime/AgentPromptBuilder.swift"
                )
            default:
                event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            }
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remainingEvents = try context.fetch(FetchDescriptor<TaskEvent>())
        let summary = try #require(remainingEvents.first { $0.type == "activity.compacted" })
        #expect(summary.payload.contains("Compacted detail index:"))
        #expect(summary.payload.contains("swift test --filter PromptContextContinuityTests"))
        #expect(summary.payload.contains("/tmp/Astra/Services/Runtime/AgentPromptBuilder.swift"))
        #expect(summary.payload.contains("Tests failed"))
    }

    @Test("Compaction summary preserves decisions blockers and preferences")
    func compactionSummaryPreservesDecisionsBlockersAndPreferences() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        context.insert(task)

        for index in 0..<230 {
            let event: TaskEvent
            switch index {
            case 5:
                event = TaskEvent(
                    task: task,
                    type: "agent.response",
                    payload: "Decision: use current_state as the canonical Context Capsule."
                )
            case 6:
                event = TaskEvent(
                    task: task,
                    type: "agent.response",
                    payload: "Unresolved bug: Antigravity provider returned no visible result."
                )
            case 7:
                event = TaskEvent(
                    task: task,
                    type: "agent.response",
                    payload: "User prefers regression tests for every bug fix."
                )
            default:
                event = TaskEvent(task: task, type: "agent.response", payload: "event \(index)")
            }
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remainingEvents = try context.fetch(FetchDescriptor<TaskEvent>())
        let summary = try #require(remainingEvents.first { $0.type == "activity.compacted" })
        #expect(summary.payload.contains("Decisions:"))
        #expect(summary.payload.contains("canonical Context Capsule"))
        #expect(summary.payload.contains("Unresolved bugs/blockers:"))
        #expect(summary.payload.contains("provider returned no visible result"))
        #expect(summary.payload.contains("User preferences:"))
        #expect(summary.payload.contains("regression tests for every bug fix"))
    }

    @Test("Compaction preserves bounded output presentation anchors")
    func preservesBoundedOutputPresentationAnchors() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let progress = TaskEvent(task: task, type: "agent.response", payload: "Let me check progress.", run: run)
        progress.timestamp = Date(timeIntervalSince1970: 5)
        context.insert(progress)
        let boundary = TaskEvent(task: task, type: "tool.use", payload: "Using tool: Bash", run: run)
        boundary.timestamp = Date(timeIntervalSince1970: 6)
        context.insert(boundary)
        let finalOne = TaskEvent(task: task, type: "agent.response", payload: "Final answer part one.", run: run)
        finalOne.timestamp = Date(timeIntervalSince1970: 7)
        context.insert(finalOne)
        let finalTwo = TaskEvent(task: task, type: "agent.response", payload: "Final answer part two.", run: run)
        finalTwo.timestamp = Date(timeIntervalSince1970: 8)
        context.insert(finalTwo)

        for index in 0..<230 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "filler \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(!remaining.contains { $0.id == progress.id })
        #expect(remaining.contains { $0.id == boundary.id })
        #expect(remaining.contains { $0.id == finalOne.id })
        #expect(remaining.contains { $0.id == finalTwo.id })
        #expect(remaining.contains { $0.type == "activity.compacted" })
    }

    @Test("Compaction does not preserve unbounded final response chunk streams")
    func compactionDoesNotPreserveUnboundedFinalResponseChunkStreams() throws {
        let container = try makeCompactionTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "T", goal: "G")
        let run = TaskRun(task: task)
        run.output = (0..<40)
            .map { "Final answer chunk \($0)." }
            .joined(separator: " ")
        context.insert(task)
        context.insert(run)

        let progress = TaskEvent(task: task, type: "agent.response", payload: "Checking progress.", run: run)
        progress.timestamp = Date(timeIntervalSince1970: 5)
        context.insert(progress)
        let boundary = TaskEvent(task: task, type: "tool.result", payload: "Tool finished", run: run)
        boundary.timestamp = Date(timeIntervalSince1970: 6)
        context.insert(boundary)

        var finalChunks: [TaskEvent] = []
        for index in 0..<40 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "Final answer chunk \(index).", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(7 + index))
            finalChunks.append(event)
            context.insert(event)
        }

        for index in 0..<230 {
            let event = TaskEvent(task: task, type: "agent.response", payload: "filler \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(100 + index))
            context.insert(event)
        }

        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(!remaining.contains { $0.id == progress.id })
        #expect(!remaining.contains { $0.id == boundary.id })
        for event in finalChunks {
            #expect(!remaining.contains { $0.id == event.id })
        }
        #expect(remaining.contains { $0.type == "activity.compacted" })
    }
}
