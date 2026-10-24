import Foundation
import ASTRAModels

/// One derived answer for the current request, owned by the view. The key is
/// exactly the text read by TaskDeliverableExpectation; streaming, review and
/// filesystem evidence stay live and are deliberately not cached here.
@MainActor
final class TaskDeliverableIntentMemo {
    private struct Input: Equatable {
        let title: String
        let goal: String
        let inputs: [String]
        let acceptanceCriteria: [String]

        init(_ task: AgentTask) {
            title = task.title
            goal = task.goal
            inputs = task.inputs
            acceptanceCriteria = task.acceptanceCriteria
        }
    }

    private var input: Input?
    private var answer = false

    func requiresArtifact(
        for task: AgentTask,
        compute: (AgentTask) -> Bool = { TaskDeliverableExpectation.requiresDeliverableArtifact($0) }
    ) -> Bool {
        let next = Input(task)
        guard input != next else { return answer }
        answer = compute(task)
        input = next
        return answer
    }
}
