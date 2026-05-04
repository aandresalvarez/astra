import Foundation
import SwiftData
import ASTRACore

struct TaskCapabilityResolver {
    private let task: AgentTask

    init(task: AgentTask) {
        self.task = task
    }

    var resolver: SkillResolver {
        let standaloneTools = allLocalTools.filter { $0.skill == nil }
        let standaloneSnapshots = standaloneTools.map(LocalToolSnapshotConfig.init(localTool:))

        let liveCLICommands = Set(
            allLocalTools
                .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
                .map(\.command)
        )

        var liveEnvVars: [String: String] = [:]
        for skill in task.skills {
            for (key, value) in skill.environmentVariables {
                liveEnvVars[key] = value
            }
        }

        var connEnvVars: [String: String] = [:]
        for connector in allConnectors {
            for (key, value) in connector.allEnvironmentVariables {
                connEnvVars[key] = value
            }
        }

        return SkillResolver(
            effectiveSnapshots: effectiveSkillSnapshots,
            detachedSnapshots: detachedSkillSnapshots,
            standaloneToolSnapshots: standaloneSnapshots,
            liveLocalToolCommands: liveCLICommands,
            liveSkillEnvVars: liveEnvVars,
            connectorEnvVars: connEnvVars
        )
    }

    var allConnectors: [Connector] {
        let enabledGlobalIDs = Set(task.workspace?.enabledGlobalConnectorIDs ?? [])
        let workspaceID = task.workspace?.id
        let fromSkills = task.skills.flatMap(\.connectors).filter { connector in
            if connector.isGlobal {
                return enabledGlobalIDs.contains(connector.id.uuidString)
            }
            return connector.workspace?.id == workspaceID
        }
        let standalone = task.workspace?.connectors.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone

        if let ws = task.workspace, !ws.enabledGlobalConnectorIDs.isEmpty, let ctx = task.modelContext {
            let enabledIDs = Set(ws.enabledGlobalConnectorIDs)
            let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
        }

        var seen = Set<UUID>()
        return all.filter { seen.insert($0.id).inserted }
    }

    var allLocalTools: [LocalTool] {
        let fromSkills = task.skills.flatMap(\.localTools)
        let standalone = task.workspace?.localTools.filter { $0.skill == nil } ?? []
        var all = fromSkills + standalone

        if let ws = task.workspace, !ws.enabledGlobalToolIDs.isEmpty, let ctx = task.modelContext {
            let enabledIDs = Set(ws.enabledGlobalToolIDs)
            let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
            if let globals = try? ctx.fetch(descriptor) {
                all += globals.filter { enabledIDs.contains($0.id.uuidString) }
            }
        }

        var seen = Set<UUID>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private var effectiveSkillSnapshots: [SkillSnapshotConfig] {
        let liveSnapshots = task.skills.map(SkillSnapshotConfig.init(skill:))
        guard !task.skillSnapshots.isEmpty else { return liveSnapshots }
        guard !liveSnapshots.isEmpty else { return task.skillSnapshots }

        var combined = liveSnapshots
        var seenIDs = Set(liveSnapshots.compactMap(\.id))
        var seenNames = Set(liveSnapshots.map { $0.name.lowercased() })

        for snapshot in task.skillSnapshots {
            let hasMatchingID = snapshot.id.map { seenIDs.contains($0) } ?? false
            let nameKey = snapshot.name.lowercased()
            guard !hasMatchingID && !seenNames.contains(nameKey) else { continue }
            combined.append(snapshot)
            if let id = snapshot.id {
                seenIDs.insert(id)
            }
            seenNames.insert(nameKey)
        }

        return combined
    }

    private var detachedSkillSnapshots: [SkillSnapshotConfig] {
        guard !task.skillSnapshots.isEmpty else { return [] }
        guard !task.skills.isEmpty else { return task.skillSnapshots }

        let liveIDs = Set(task.skills.map { $0.id.uuidString })
        let liveNames = Set(task.skills.map { $0.name.lowercased() })

        return task.skillSnapshots.filter { snapshot in
            if let id = snapshot.id, liveIDs.contains(id) {
                return false
            }
            return !liveNames.contains(snapshot.name.lowercased())
        }
    }
}
