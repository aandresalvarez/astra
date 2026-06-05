import Testing
import Foundation
@testable import ASTRA

@Suite("Event Categories")
struct EventCategoryTests {
    private struct ExamplePayload: Codable, Equatable {
        var message: String
        var count: Int
    }

    @Test("Lifecycle events categorized correctly")
    func lifecycleCategory() {
        let types = ["task.started", "task.completed", "task.cancelled", "task.interrupted",
                     "task.retried", "task.resumed", "task.approved", "task.dismissed",
                     "activity.compacted"]
        for type in types {
            #expect(TaskEvent.categoryFor(type: type) == "lifecycle", "Expected 'lifecycle' for \(type)")
        }
    }

    @Test("Conversation events categorized correctly")
    func conversationCategory() {
        let types = ["user.message", "agent.response", "agent.thinking"]
        for type in types {
            #expect(TaskEvent.categoryFor(type: type) == "conversation", "Expected 'conversation' for \(type)")
        }
    }

    @Test("Tool events categorized correctly")
    func toolCategory() {
        let types = ["tool.use", "permission.denied"]
        for type in types {
            #expect(TaskEvent.categoryFor(type: type) == "tool", "Expected 'tool' for \(type)")
        }
    }

    @Test("System events categorized correctly")
    func systemCategory() {
        let types = ["error", "budget.exceeded", "task.stats", "task.chained",
                     "astra.todo.replace", "astra.complete", "astra.protocol.invalid"]
        for type in types {
            #expect(TaskEvent.categoryFor(type: type) == "system", "Expected 'system' for \(type)")
        }
    }

    @Test("Team events categorized correctly")
    func teamCategory() {
        let types = ["team.created", "team.deleted", "team.message",
                     "team.agent.started", "team.agent.completed"]
        for type in types {
            #expect(TaskEvent.categoryFor(type: type) == "team", "Expected 'team' for \(type)")
        }
    }

    @Test("Unknown type defaults to system")
    func unknownDefaultsToSystem() {
        #expect(TaskEvent.categoryFor(type: "some.random.type") == "system")
    }

    @Test("Category is set on init")
    func categorySetOnInit() {
        let task = AgentTask(title: "Test", goal: "test")
        let event = TaskEvent(task: task, type: "tool.use", payload: "Using Bash")
        #expect(event.category == "tool")

        let event2 = TaskEvent(task: task, type: "agent.response", payload: "Hello")
        #expect(event2.category == "conversation")
    }

    @Test("Typed event names preserve persisted raw strings and categories")
    func typedNamesPreserveRawStringsAndCategories() {
        #expect(TaskEventTypes.Task.completed.rawValue == "task.completed")
        #expect(TaskEventTypes.Conversation.userMessage.rawValue == "user.message")
        #expect(TaskEventTypes.Tool.use.rawValue == "tool.use")
        #expect(TaskEventTypes.Budget.warning.rawValue == "budget.warning")
        #expect(TaskEventTypes.Validation.contractFailed.rawValue == "validation.contract.failed")

        #expect(TaskEventTypes.Task.completed.category == .lifecycle)
        #expect(TaskEventTypes.Conversation.userMessage.category == .conversation)
        #expect(TaskEventTypes.Tool.use.category == .tool)
        #expect(TaskEventTypes.Budget.warning.category == .system)
        #expect(TaskEventTypes.Team.message.category == .team)
    }

    @Test("Legacy event namespaces are backed by typed event names")
    func legacyEventNamespacesUseTypedEventNames() {
        #expect(TaskPlanEventTypes.created == TaskEventTypes.Plan.created.rawValue)
        #expect(TaskPlanEventTypes.stepCompleted == TaskEventTypes.Plan.stepCompleted.rawValue)
        #expect(TaskValidationEventTypes.contractPassed == TaskEventTypes.Validation.contractPassed.rawValue)
        #expect(TaskValidationEventTypes.assertionFailed == TaskEventTypes.Validation.assertionFailed.rawValue)
        #expect(TaskValidationBehaviorEventTypes.evidenceAttached == TaskEventTypes.Validation.behaviorEvidenceAttached.rawValue)
        #expect(TaskVerifierEventTypes.completed == TaskEventTypes.Verifier.completed.rawValue)
        #expect(TaskDeliverableVerificationEventTypes.reviewNeeded == TaskEventTypes.Deliverable.verificationReviewNeeded.rawValue)
        #expect(TaskHandoffEventTypes.created == TaskEventTypes.Handoff.created.rawValue)
        #expect(TaskCorrectiveEventTypes.taskCreated == TaskEventTypes.Corrective.taskCreated.rawValue)
        #expect(TaskResourceLockEventTypes.acquired == TaskEventTypes.ResourceLock.acquired.rawValue)
        #expect(TaskMissionActionEventTypes.correctionCreated == TaskEventTypes.Mission.actionCorrectionCreated.rawValue)
        #expect(TaskMissionEventTypes.auditBundleCreated == TaskEventTypes.Mission.auditBundleCreated.rawValue)
        #expect(TaskRoleProfileEventTypes.changed == TaskEventTypes.RoleProfile.changed.rawValue)
        #expect(TaskRuntimePermissionGrants.eventType == TaskEventTypes.Tool.permissionGrantTask.rawValue)
    }

    @Test("Typed initializer remains compatible with persisted string fields")
    func typedInitializerWritesPersistedStringFields() {
        let task = AgentTask(title: "Test", goal: "test")
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.use,
            payload: "Tool call"
        )

        #expect(event.type == "tool.use")
        #expect(event.eventType == TaskEventTypes.Tool.use)
        #expect(event.hasType(TaskEventTypes.Tool.use))
        #expect(event.category == "tool")
        #expect(event.typedCategory == .tool)
        #expect(TaskEventTypes.Tool.permissionApprovalRequested.category == .system)
    }

    @Test("Typed payload decoder reports type mismatches and decode failures")
    func typedPayloadDecoderReportsFailures() throws {
        let task = AgentTask(title: "Test", goal: "test")
        let payload = ExamplePayload(message: "hello", count: 2)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: json
        )

        switch event.decodePayload(as: ExamplePayload.self, expecting: TaskEventTypes.System.info) {
        case .success(let decoded):
            #expect(decoded == payload)
        case .failure(let error):
            Issue.record("Expected payload decode to succeed, got \(error)")
        }

        #expect(event.decodePayload(
            as: ExamplePayload.self,
            expecting: TaskEventTypes.System.error
        ) == .failure(.typeMismatch(expected: "error", actual: "system.info")))

        let invalidEvent = TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: "not-json"
        )
        switch invalidEvent.decodePayload(as: ExamplePayload.self, expecting: TaskEventTypes.System.info) {
        case .success:
            Issue.record("Expected invalid JSON payload to fail decoding")
        case .failure(let error):
            guard case .decodingFailed = error else {
                Issue.record("Expected decoding failure, got \(error)")
                return
            }
        }
    }
}
