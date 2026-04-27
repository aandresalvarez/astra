import Foundation
import ASTRACore

struct SkillResolver {
    struct ToolPermissionConflict: Equatable {
        let tool: String
        let allowedBy: String
        let disallowedBy: String
    }

    let effectiveSnapshots: [SkillSnapshotConfig]
    let detachedSnapshots: [SkillSnapshotConfig]
    let standaloneToolSnapshots: [LocalToolSnapshotConfig]
    let liveLocalToolCommands: Set<String>
    let liveSkillEnvVars: [String: String]
    let connectorEnvVars: [String: String]

    var resolvedAllowedTools: [String] {
        var tools: [String] = []
        for snapshot in effectiveSnapshots {
            tools.append(contentsOf: snapshot.allowedTools)
            tools.append(contentsOf: snapshot.customTools)
            let localToolSnapshots = snapshot.localToolSnapshots ?? []
            for tool in localToolSnapshots where !tool.command.isEmpty {
                tools.append(tool.command)
            }
            let hasCLITools = localToolSnapshots.contains { $0.toolType != "mcp" && !$0.command.isEmpty }
            if hasCLITools && !tools.contains("Bash") {
                tools.append("Bash")
            }
        }

        for tool in standaloneToolSnapshots where !tool.command.isEmpty {
            tools.append(tool.command)
        }
        let hasStandaloneCLI = standaloneToolSnapshots.contains { $0.toolType != "mcp" && !$0.command.isEmpty }
        if hasStandaloneCLI && !tools.contains("Bash") {
            tools.append("Bash")
        }
        let allowed = tools.isEmpty ? Skill.defaultAllowed : Array(Set(tools))
        let disallowed = Set(resolvedDisallowedTools)
        return allowed.filter { !disallowed.contains($0) }.sorted()
    }

    var resolvedDisallowedTools: [String] {
        Array(Set(effectiveSnapshots.flatMap(\.disallowedTools))).sorted()
    }

    var toolPermissionConflicts: [ToolPermissionConflict] {
        var conflicts: [ToolPermissionConflict] = []
        let disallowedByTool = Dictionary(
            uniqueKeysWithValues: effectiveSnapshots.flatMap { snapshot in
                snapshot.disallowedTools.map { ($0, snapshot.name) }
            }
        )

        for snapshot in effectiveSnapshots {
            var allowedTools = snapshot.allowedTools + snapshot.customTools
            let localToolSnapshots = snapshot.localToolSnapshots ?? []
            for tool in localToolSnapshots where !tool.command.isEmpty {
                allowedTools.append(tool.command)
            }
            let hasCLITools = localToolSnapshots.contains { $0.toolType != "mcp" && !$0.command.isEmpty }
            if hasCLITools && !allowedTools.contains("Bash") {
                allowedTools.append("Bash")
            }

            for tool in Set(allowedTools).sorted() {
                guard let disallowedBy = disallowedByTool[tool], disallowedBy != snapshot.name else { continue }
                conflicts.append(ToolPermissionConflict(tool: tool, allowedBy: snapshot.name, disallowedBy: disallowedBy))
            }
        }

        return conflicts.sorted {
            if $0.tool != $1.tool { return $0.tool < $1.tool }
            if $0.allowedBy != $1.allowedBy { return $0.allowedBy < $1.allowedBy }
            return $0.disallowedBy < $1.disallowedBy
        }
    }

    var resolvedClaudeAllowedTools: [String] {
        let snapshotCLICommands = effectiveSnapshots
            .flatMap { $0.localToolSnapshots ?? [] }
            .filter { $0.toolType != "mcp" && !$0.command.isEmpty }
            .map(\.command)
        let cliLocalCommands = liveLocalToolCommands.union(snapshotCLICommands)
        return resolvedAllowedTools.filter { !cliLocalCommands.contains($0) }
    }

    var resolvedBehaviorInstructions: String {
        effectiveSnapshots.compactMap { snapshot in
            snapshot.behaviorInstructions.isEmpty ? nil : "[\(snapshot.name)]:\n\(snapshot.behaviorInstructions)"
        }.joined(separator: "\n\n")
    }

    var resolvedEnvironmentVariables: [String: String] {
        var merged: [String: String] = [:]
        for (key, value) in liveSkillEnvVars {
            merged[key] = value
        }
        for snapshot in detachedSnapshots {
            for (key, value) in snapshotEnvironmentVariables(for: snapshot) {
                merged[key] = value
            }
            for connectorSnapshot in snapshot.connectorSnapshots ?? [] {
                for (key, value) in snapshotConnectorEnvironmentVariables(for: connectorSnapshot) {
                    merged[key] = value
                }
            }
        }
        for (key, value) in connectorEnvVars {
            merged[key] = value
        }
        return merged
    }

    private func snapshotEnvironmentVariables(for snapshot: SkillSnapshotConfig) -> [String: String] {
        let values = normalizedParallelArray(keys: snapshot.environmentKeys, values: snapshot.environmentValues)
        return Dictionary(zip(snapshot.environmentKeys, values), uniquingKeysWith: { _, last in last })
    }

    private func snapshotConnectorEnvironmentVariables(for snapshot: ConnectorSnapshotConfig) -> [String: String] {
        let values = normalizedParallelArray(keys: snapshot.configKeys, values: snapshot.configValues)
        return Dictionary(zip(snapshot.configKeys, values), uniquingKeysWith: { _, last in last })
    }

    private func normalizedParallelArray(keys: [String], values: [String]) -> [String] {
        if values.count == keys.count {
            return values
        } else if values.count > keys.count {
            return Array(values.prefix(keys.count))
        } else {
            return values + Array(repeating: "", count: keys.count - values.count)
        }
    }
}
