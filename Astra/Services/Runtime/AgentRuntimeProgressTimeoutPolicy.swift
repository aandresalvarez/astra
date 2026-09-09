import Foundation
import ASTRACore
import ASTRAModels

enum AgentRuntimeProgressTimeoutPolicy {
    /// The window is deliberately phase-independent. Writing the deliverable is
    /// what needs the extra room, and that most often happens on a resume: the
    /// earlier run did the discovery, so the continuation goes straight to the
    /// long write. Gating this on `.run` gave the tight window to exactly the
    /// runs that needed the wide one.
    static func semanticProgressTimeout(
        task: AgentTask,
        phase _: RunPhase,
        idleTimeoutSeconds: TimeInterval
    ) -> TimeInterval {
        guard TaskDeliverableExpectation.requiresDeliverableArtifact(task) else {
            return min(idleTimeoutSeconds, 180)
        }

        let artifactWindow = idleTimeoutSeconds * 2
        guard idleTimeoutSeconds >= 60 else {
            return artifactWindow
        }
        return min(max(artifactWindow, 180), 360)
    }
}
