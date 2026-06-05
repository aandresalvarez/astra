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
        #expect(plan.validationContract == nil)
    }

    @Test("Structured ASTRA_PLAN payload parses validation contract assertions")
    func structuredPlanParsesValidationContract() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"version":1,"planID":"\(planID.uuidString)","title":"Plan mode","goal":"Ship plan mode","steps":[{"id":"step-1","title":"Inspect code","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"Context gathered"}],"validationContract":{"version":1,"assertions":[{"id":"tests-pass","scope":"plan","description":"Focused tests pass","method":"command","required":true,"command":"swift test --filter TaskPlanServiceTests"},{"id":"artifact-exists","scope":"step","stepID":"step-1","description":"Report artifact exists","method":"artifact","required":false,"path":"outputs/report.md"}]}}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))
        let contract = try #require(plan.validationContract)

        #expect(contract.assertions.count == 2)
        #expect(contract.assertions[0].id == "tests-pass")
        #expect(contract.assertions[0].method == .command)
        #expect(contract.assertions[0].required)
        #expect(contract.assertions[0].command == "swift test --filter TaskPlanServiceTests")
        #expect(contract.assertions[1].scope == .step)
        #expect(contract.assertions[1].stepID == "step-1")
        #expect(contract.assertions[1].method == .artifact)

        let encoded = TaskPlanService.encodePlanPayload(plan)
        #expect(encoded.contains("\"validationContract\""))
        #expect(encoded.contains("\"assertionID\"") == false)

        let roundTrip = try #require(TaskPlanService.decodePlanPayload(encoded))
        #expect(roundTrip.validationContract == contract)
    }

    @Test("Structured ASTRA_PLAN payload parses step outputs")
    func structuredPlanParsesStepOutputs() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"version":1,"planID":"\(planID.uuidString)","title":"Artifact plan","goal":"Write nested artifacts","steps":[{"id":"requirements","title":"Write requirements","status":"pending","risk":"low","likelyTools":["Write"],"doneSignal":"docs/requirements.md exists","outputs":[{"kind":"file","scope":"task_output","path":"docs/requirements.md","required":true,"prepareParentDirectories":true},{"kind":"directory","scope":"task_output","path":"assets/","required":false}]}]}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))
        let outputs = plan.steps[0].outputs

        #expect(outputs.count == 2)
        #expect(outputs[0].kind == .file)
        #expect(outputs[0].scope == .taskOutput)
        #expect(outputs[0].path == "docs/requirements.md")
        #expect(outputs[0].prepareParentDirectories)
        #expect(outputs[0].source == "step:requirements")
        #expect(outputs[1].kind == .directory)
        #expect(outputs[1].path == "assets/")

        let encoded = TaskPlanService.encodePlanPayload(plan)
        #expect(encoded.contains("\"outputs\""))
        let roundTrip = try #require(TaskPlanService.decodePlanPayload(encoded))
        #expect(roundTrip.steps[0].outputs == outputs)
    }

    @Test("Structured ASTRA_PLAN payload parses verifier validation assertions")
    func structuredPlanParsesVerifierValidationAssertion() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"version":1,"planID":"\(planID.uuidString)","title":"Verifier plan","goal":"Review independently","steps":[{"id":"review","title":"Review","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"Verifier passes"}],"validationContract":{"version":1,"assertions":[{"id":"verifier-review","scope":"plan","description":"Independent verifier approves the result","method":"verifier","required":true}]}}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))
        let assertion = try #require(plan.validationContract?.assertions.first)
        #expect(assertion.method == .verifier)
        #expect(assertion.description == "Independent verifier approves the result")
    }

    @Test("Structured ASTRA_PLAN payload parses browser behavior validation assertions")
    func structuredPlanParsesBrowserBehaviorValidationAssertion() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"version":1,"planID":"\(planID.uuidString)","title":"Browser plan","goal":"Validate browser output","steps":[{"id":"browser","title":"Browser","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"Behavior passes"}],"validationContract":{"version":1,"assertions":[{"id":"browser-visible","scope":"plan","description":"Checkout Ready is visible","method":"browser_behavior","required":true,"path":"index.html","evidenceQuery":"Checkout Ready"}]}}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))
        let assertion = try #require(plan.validationContract?.assertions.first)
        #expect(assertion.method == .browserBehavior)
        #expect(assertion.path == "index.html")
        #expect(assertion.evidenceQuery == "Checkout Ready")
    }

    @Test("Structured ASTRA_PLAN payload parses text contains validation assertions")
    func structuredPlanParsesTextContainsValidationAssertion() throws {
        let planID = UUID(uuidString: "6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87")!
        let text = """
        ASTRA_PLAN {"version":1,"planID":"\(planID.uuidString)","title":"Text plan","goal":"Validate artifact text","steps":[{"id":"write","title":"Write page","status":"pending","risk":"low","likelyTools":["Write"],"doneSignal":"Page exists"}],"validationContract":{"version":1,"assertions":[{"id":"page-text","scope":"plan","description":"Page names Med13","method":"file_contains","required":true,"path":"index.html","evidenceQuery":"Med13 Foundation"}]}}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))
        let assertion = try #require(plan.validationContract?.assertions.first)
        #expect(assertion.method == .textContains)
        #expect(assertion.path == "index.html")
        #expect(assertion.evidenceQuery == "Med13 Foundation")
    }

    @Test("Invalid validation contract assertions are dropped without rejecting old plan payload")
    func invalidValidationContractAssertionsAreDropped() throws {
        let text = """
        ASTRA_PLAN {"version":1,"planID":"6E5D41A5-67DE-43F3-B9FB-3DA6D58D4F87","title":"Plan","goal":"Do work","steps":[{"id":"step-1","title":"Do it","status":"pending"}],"validationContract":{"version":1,"assertions":[{"id":"bad-step","scope":"step","stepID":"missing","description":"Missing step","method":"command","required":true,"command":"true"}]}}
        """

        let plan = try #require(TaskPlanService.parsePlanPayload(from: text))

        #expect(plan.steps.count == 1)
        #expect(plan.validationContract == nil)
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

    @Test("Plan cache signature changes for same-length plan payload edits")
    func planCacheSignatureTracksSameLengthPayloadEdits() {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let event = TaskEvent(task: task, type: TaskPlanEventTypes.created, payload: "aaaa")
        task.events.append(event)
        let before = TaskPlanStateCacheSignature(task: task)

        event.payload = "bbbb"
        let after = TaskPlanStateCacheSignature(task: task)

        #expect(after != before)
    }

    @Test("Plan state snapshot refreshes only when signature changes")
    func planStateSnapshotRefreshesOnlyWhenSignatureChanges() {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let cached = TaskPlanStateSnapshot.build(for: task)

        #expect(TaskPlanStateSnapshot.refreshed(for: task, cached: cached) == nil)

        let plan = TaskPlanPayload(
            title: "Plan",
            goal: "Do work",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Inspect")]
        )
        task.events.append(TaskEvent(
            task: task,
            type: TaskPlanEventTypes.created,
            payload: TaskPlanService.encodePlanPayload(plan)
        ))

        let refreshed = TaskPlanStateSnapshot.refreshed(for: task, cached: cached)

        #expect(refreshed?.signature != cached.signature)
        #expect(refreshed?.state.plan?.title == "Plan")
        #expect(refreshed?.state.plan?.steps.map(\.id) == ["step-1"])
    }

    @Test("Plan cache signature ignores unrelated event insertion positions")
    func planCacheSignatureIgnoresUnrelatedEventInsertionPositions() {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let event = TaskEvent(task: task, type: TaskPlanEventTypes.created, payload: "aaaa")
        task.events.append(event)
        let before = TaskPlanStateCacheSignature(task: task)

        let unrelatedEvent = TaskEvent(task: task, type: "agent.response", payload: "noise")
        task.events.insert(unrelatedEvent, at: 0)
        let after = TaskPlanStateCacheSignature(task: task)

        #expect(after == before)
    }

    @Test("Plan cache signature changes for same-length run output edits")
    func planCacheSignatureTracksSameLengthRunOutputEdits() {
        let task = AgentTask(title: "Plan task", goal: "Do work")
        let run = TaskRun(task: task)
        run.output = #"ASTRA_EVENT {"type":"plan.step.completed","summary":"aaaa"}"#
        task.runs.append(run)
        let before = TaskPlanStateCacheSignature(task: task)

        run.output = #"ASTRA_EVENT {"type":"plan.step.completed","summary":"bbbb"}"#
        let after = TaskPlanStateCacheSignature(task: task)

        #expect(after != before)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
