import Foundation
import SwiftData
import ASTRAModels

/// Owns an unmanaged launch graph. SwiftData's inverse relationships keep
/// detached task/event/run graphs alive even after the last plain task reference
/// is dropped. Keep this owner (not just `task`) for every asynchronous user.
@MainActor
final class DetachedLaunchProjection {
    let task: AgentTask

    init(_ snapshot: AgentTaskLaunchSnapshot, from source: AgentTask) {
        task = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: source)
    }

    isolated deinit {
        Self.releaseUnmanagedGraph(task)
    }

    /// First collect and validate every reachable node. An accidental live
    /// model edge must never turn memory cleanup into a persistence mutation.
    /// Identity here is object identity, not the UUID copied from saved rows.
    private static func releaseUnmanagedGraph(_ root: AgentTask) {
        var nodes: [any PersistentModel] = [root]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        func add(_ node: (any PersistentModel)?) {
            guard let node, seen.insert(ObjectIdentifier(node)).inserted else { return }
            nodes.append(node)
        }
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            guard node.modelContext == nil else { return }
            switch node {
            case let task as AgentTask:
                add(task.workspace)
                task.events.forEach { add($0) }; task.runs.forEach { add($0) }
                task.artifacts.forEach { add($0) }; task.skills.forEach { add($0) }
            case let event as TaskEvent: add(event.task); add(event.run)
            case let run as TaskRun: add(run.task)
            case let artifact as Artifact: add(artifact.task)
            case let workspace as Workspace:
                // These are not part of the detached launch projection.
                guard workspace.templates.isEmpty, workspace.schedules.isEmpty else { return }
                workspace.tasks.forEach { add($0) }; workspace.skills.forEach { add($0) }
                workspace.connectors.forEach { add($0) }; workspace.localTools.forEach { add($0) }
                workspace.pluginActivations.forEach { add($0) }
            case let skill as Skill:
                add(skill.workspace); skill.tasks.forEach { add($0) }
                skill.connectors.forEach { add($0) }; skill.localTools.forEach { add($0) }
            case let connector as Connector:
                add(connector.workspace); add(connector.skill); connector.accountBindings.forEach { add($0) }
            case let tool as LocalTool: add(tool.workspace); add(tool.skill)
            case let activation as PluginActivation:
                add(activation.workspace); activation.bindings.forEach { add($0) }
            case let binding as AccountBinding: add(binding.activation); add(binding.account)
            default: return
            }
            index += 1
        }
        // Clear inverse collections in bulk before individual links. Removing
        // events one at a time from a long relationship can become quadratic.
        for node in nodes {
            switch node {
            case let task as AgentTask:
                task.events = []; task.runs = []; task.artifacts = []; task.skills = []
            case let workspace as Workspace:
                workspace.tasks = []; workspace.skills = []; workspace.connectors = []
                workspace.localTools = []; workspace.pluginActivations = []
            case let skill as Skill: skill.tasks = []; skill.connectors = []; skill.localTools = []
            case let connector as Connector: connector.accountBindings = []
            case let activation as PluginActivation: activation.bindings = []
            default: break
            }
        }
        for node in nodes {
            switch node {
            case let task as AgentTask: task.workspace = nil
            case let event as TaskEvent: event.task = nil; event.run = nil
            case let run as TaskRun: run.task = nil
            case let artifact as Artifact: artifact.task = nil
            case let skill as Skill: skill.workspace = nil
            case let connector as Connector: connector.workspace = nil; connector.skill = nil
            case let tool as LocalTool: tool.workspace = nil; tool.skill = nil
            case let activation as PluginActivation: activation.workspace = nil
            case let binding as AccountBinding: binding.activation = nil; binding.account = nil
            default: break
            }
        }
    }
}
