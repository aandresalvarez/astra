import Foundation
import ASTRACore

/// Pure slice of `Astra/Services/Capabilities/TaskCapabilitySnapshotter.swift`,
/// extracted for Track A4 (`ASTRAPersistence`): `TaskCapabilitySnapshotter.capture(for:)`
/// itself has zero dependencies beyond `AgentTask`/`SkillSnapshotConfig`
/// (both Models-visible), unlike its sibling `refreshForFreshRun`, which
/// calls `AppLogger` and stays app-side.
public enum TaskCapabilitySnapshotCapture {
    public static func capture(for task: AgentTask) {
        task.skillSnapshots = task.skills.map(SkillSnapshotConfig.init(skill:))
    }
}
