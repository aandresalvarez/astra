import Foundation
import ASTRACore

enum AgentRuntimeProgressTimeoutPolicy {
    static func semanticProgressTimeout(
        task: AgentTask,
        phase: RunPhase,
        idleTimeoutSeconds: TimeInterval
    ) -> TimeInterval {
        guard phase == .run,
              TaskDeliverableExpectation.requiresDeliverableArtifact(task) else {
            return min(idleTimeoutSeconds, 180)
        }

        let artifactWindow = idleTimeoutSeconds * 2
        guard idleTimeoutSeconds >= 60 else {
            return artifactWindow
        }
        return min(max(artifactWindow, 180), 360)
    }
}
