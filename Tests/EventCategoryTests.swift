import Testing
import Foundation
@testable import ASTRA

@Suite("Event Categories")
struct EventCategoryTests {

    @Test("Lifecycle events categorized correctly")
    func lifecycleCategory() {
        let types = ["task.started", "task.completed", "task.cancelled",
                     "task.retried", "task.resumed", "task.approved", "activity.compacted"]
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
}
