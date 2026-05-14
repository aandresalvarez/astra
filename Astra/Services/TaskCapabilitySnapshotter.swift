import Foundation
import ASTRACore

enum TaskCapabilitySnapshotter {
    static func capture(for task: AgentTask) {
        task.skillSnapshots = task.skills.map(SkillSnapshotConfig.init(skill:))
    }
}
