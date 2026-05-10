import Foundation
import Testing
@testable import ASTRA

@Suite("Task Plan Service")
struct TaskPlanServiceTests {
    @Test("Structured ASTRA_PLAN payload is parsed and normalized")
    func structuredPlanParses() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"goal":"Ship plan mode","planID":"\(planID.uuidString)","steps":[{"id":"step-1","title":"Inspect code","risk":"low","likelyTools":["Read","Read"],"doneSignal":"Context gathered"}],"title":"Plan mode","version":1}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))

        #expect(plan.planID == planID)
        #expect(plan.title == "Plan mode")
        #expect(plan.goal == "Ship plan mode")
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].likelyTools == ["Read"])
    }

    @Test("Visible planning text strips ASTRA_PLAN marker while preserving prose")
    func visiblePlanningTextStripsStructuredMarker() {
        let text = """
        A landing page for a MED13 research group. I can plan this with a few assumptions.

        ASTRA_PLAN {"version":1,"planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","title":"MED13 landing page","goal":"Create a static landing page","steps":[{"id":"scaffold","title":"Create HTML structure","detail":"Create index.html","status":"pending","risk":"low","likelyTools":["Write"],"doneSignal":"index.html exists"}]}

        What content should go in the Team and Publications sections?
        """

        let visible = TaskPlanService.userVisiblePlanningText(from: text)

        #expect(visible.contains("A landing page for a MED13 research group"))
        #expect(visible.contains("What content should go in the Team and Publications sections?"))
        #expect(!visible.contains("ASTRA_PLAN"))
        #expect(!visible.contains("\"steps\""))
        #expect(!visible.contains("planID"))
    }

    @Test("Visible planning text returns friendly fallback for marker-only responses")
    func visiblePlanningTextFallbackForMarkerOnlyResponse() {
        let text = """
        ASTRA_PLAN {"version":1,"planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","title":"Plan","goal":"Do work","steps":[{"id":"step-1","title":"Do it","status":"pending"}]}
        """

        let visible = TaskPlanService.userVisiblePlanningText(from: text)

        #expect(visible == "I prepared a plan. Review it in the Plan panel, then run it when you're ready.")
    }

    @Test("Structured plan enriches file creation steps with write tools")
    func structuredPlanEnrichesMutationTools() throws {
        let text = """
        ASTRA_PLAN {"version":1,"planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","title":"Website","goal":"Create a static website","steps":[{"id":"home","title":"Create site structure and homepage","detail":"Build index.html with responsive sections.","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"index.html exists"}]}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))

        #expect(plan.steps[0].likelyTools.contains("Read"))
        #expect(plan.steps[0].likelyTools.contains("Write"))
        #expect(!plan.steps[0].likelyTools.contains("Bash"))
    }

    @Test("Unstructured planning text falls back to ordered steps")
    func fallbackPlanFromList() {
        let plan = TaskPlanService.parsePlan(
            from: """
            Proposed plan
            1. Inspect current implementation.
            2. Run focused tests.
            """,
            fallbackGoal: "Improve plan mode"
        )

        #expect(plan.title == "Proposed plan")
        #expect(plan.goal == "Improve plan mode")
        #expect(plan.steps.map(\.id) == ["step-1", "step-2"])
        #expect(plan.steps[0].title == "Inspect current implementation.")
        #expect(plan.steps[1].likelyTools.contains("Bash"))
    }

    @Test("Plan state reconstructs lifecycle and step progress from events")
    func reconstructsPlanLifecycle() throws {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let plan = TaskPlanPayload(
            planID: UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!,
            title: "Do work plan",
            goal: "Do work",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect"),
                TaskPlanPayloadStep(id: "step-2", title: "Verify")
            ]
        )

        let created = TaskEvent(task: task, type: TaskPlanEventTypes.created, payload: TaskPlanService.encodePlanPayload(plan))
        let approved = TaskEvent(task: task, type: TaskPlanEventTypes.approved, payload: TaskPlanService.encodePlanPayload(plan))
        let startedPayload = TaskPlanLifecyclePayload(planID: plan.planID)
        let started = TaskEvent(task: task, type: TaskPlanEventTypes.executionStarted, payload: encode(startedPayload))
        let completedPayload = TaskPlanProgressPayload(
            version: 1,
            type: TaskPlanEventTypes.stepCompleted,
            planID: plan.planID,
            stepID: "step-1",
            status: .done,
            title: nil,
            detail: nil,
            summary: "Inspected",
            reason: nil
        )
        let completed = TaskEvent(task: task, type: TaskPlanEventTypes.stepCompleted, payload: TaskPlanService.encodeStepProgressPayload(completedPayload))

        for (index, event) in [created, approved, started, completed].enumerated() {
            event.timestamp = Date(timeIntervalSince1970: TimeInterval(index))
        }

        let state = TaskPlanService.reconstruct(from: [completed, started, approved, created])

        #expect(state.lifecycleStatus == .executing)
        #expect(state.approvedAt == approved.timestamp)
        #expect(state.executionStartedAt == started.timestamp)
        #expect(state.plan?.steps[0].status == .done)
        #expect(state.plan?.steps[0].doneSignal == "Inspected")
        #expect(state.plan?.steps[1].status == .pending)
    }

    @Test("Blocked permission reason enriches step tools for retry")
    func blockedPermissionReasonEnrichesStepToolsForRetry() throws {
        let task = AgentTask(title: "Plan task", goal: "Create HTML")
        let plan = TaskPlanPayload(
            planID: UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!,
            title: "Website",
            goal: "Create a website",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Create homepage", likelyTools: ["Read"])
            ]
        )
        let blocked = TaskPlanProgressPayload(
            version: 1,
            type: TaskPlanEventTypes.stepBlocked,
            planID: plan.planID,
            stepID: "step-1",
            status: .blocked,
            title: nil,
            detail: nil,
            summary: nil,
            reason: "Write permission needed to create .astra/tasks/97EF1FD6/index.html."
        )

        let created = TaskEvent(task: task, type: TaskPlanEventTypes.created, payload: TaskPlanService.encodePlanPayload(plan))
        let approved = TaskEvent(task: task, type: TaskPlanEventTypes.approved, payload: TaskPlanService.encodePlanPayload(plan))
        let progress = TaskEvent(task: task, type: TaskPlanEventTypes.stepBlocked, payload: TaskPlanService.encodeStepProgressPayload(blocked))

        let state = TaskPlanService.reconstruct(from: [created, approved, progress])

        #expect(state.plan?.steps[0].status == .blocked)
        #expect(state.plan?.steps[0].detail.contains("Write permission needed") == true)
        #expect(state.plan?.steps[0].likelyTools.contains("Write") == true)
    }

    @Test("Next executable step skips completed and skipped steps")
    func nextExecutableStepSkipsHistoricalSteps() throws {
        let plan = TaskPlanPayload(
            title: "Step gate",
            goal: "Continue safely",
            steps: [
                TaskPlanPayloadStep(id: "done", title: "Done", status: .done),
                TaskPlanPayloadStep(id: "skipped", title: "Skipped", status: .skipped),
                TaskPlanPayloadStep(id: "next", title: "Needs approval", status: .pending),
                TaskPlanPayloadStep(id: "later", title: "Later", status: .pending)
            ]
        )

        let next = try #require(TaskPlanService.nextExecutableStep(in: plan))

        #expect(next.id == "next")
        #expect(TaskPlanService.hasRemainingExecutableSteps(in: plan))
    }

    @Test("Plan canvas editability is limited to non-run steps")
    func editabilityIsLimitedToFutureSteps() {
        let plan = TaskPlanPayload(
            title: "Plan",
            goal: "Edit remaining work",
            steps: [
                TaskPlanPayloadStep(id: "done", title: "Completed", status: .done),
                TaskPlanPayloadStep(id: "running", title: "Running", status: .running),
                TaskPlanPayloadStep(id: "pending", title: "Pending", status: .pending),
                TaskPlanPayloadStep(id: "blocked", title: "Blocked", status: .blocked),
                TaskPlanPayloadStep(id: "skipped", title: "Skipped", status: .skipped)
            ]
        )

        #expect(plan.steps.map(TaskPlanService.isEditablePlanStep) == [false, false, true, true, false])
        #expect(TaskPlanService.editableStepCount(in: plan) == 2)
    }

    @Test("Plan canvas creates stable unique step IDs")
    func uniqueStepIDsUseReadableSlug() {
        let plan = TaskPlanPayload(
            title: "Plan",
            goal: "Edit remaining work",
            steps: [
                TaskPlanPayloadStep(id: "fill-foundation-content", title: "Fill foundation content"),
                TaskPlanPayloadStep(id: "fill-foundation-content-2", title: "Fill foundation content again")
            ]
        )

        #expect(TaskPlanService.makeUniqueStepID(in: plan, preferredTitle: "Fill foundation content") == "fill-foundation-content-3")
        #expect(TaskPlanService.makeUniqueStepID(in: plan, preferredTitle: "Style responsive polish") == "style-responsive-polish")
    }

    @Test("Plan state recovers persisted protocol progress from run output")
    func reconstructsRecoveredProtocolProgressFromRunOutput() throws {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let plan = TaskPlanPayload(
            planID: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            title: "Do work plan",
            goal: "Do work",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Create HTML"),
                TaskPlanPayloadStep(id: "step-2", title: "Write CSS")
            ]
        )

        let created = TaskEvent(task: task, type: TaskPlanEventTypes.created, payload: TaskPlanService.encodePlanPayload(plan))
        let approved = TaskEvent(task: task, type: TaskPlanEventTypes.approved, payload: TaskPlanService.encodePlanPayload(plan))
        let started = TaskEvent(
            task: task,
            type: TaskPlanEventTypes.executionStarted,
            payload: encode(TaskPlanLifecyclePayload(planID: plan.planID))
        )
        task.events.append(contentsOf: [created, approved, started])

        let run = TaskRun(task: task)
        run.output = """
        ● ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"\(plan.planID.uuidString)",
           "stepID":"step-1","status":"done","summary":"Created index.html"}
        ● ASTRA_EVENT {"v":1,"type":"plan.step.completed","planID":"\(plan.planID.uuidString)",
           "stepID":"step-2","status":"done","summary":"Created styles.css with black and white design"}
        """
        task.runs.append(run)

        let state = TaskPlanService.reconstruct(for: task)

        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.map(\.status) == [.done, .done])
        #expect(state.plan?.steps[0].doneSignal == "Created index.html")
        #expect(state.plan?.steps[1].doneSignal == "Created styles.css with black and white design")
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
