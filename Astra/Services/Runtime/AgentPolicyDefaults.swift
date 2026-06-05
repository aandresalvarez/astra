import Foundation
import ASTRACore

enum AgentPolicyDefaults {
    private static let workspaceDefaultsKey = "astra.policy.workspaceDefaults.v1"
    private static let globalCustomPolicyKey = "astra.policy.custom.global.v1"
    private static let workspaceCustomPoliciesKey = "astra.policy.custom.workspace.v1"

    static func effectiveLevel(
        workspace: Workspace?,
        globalDefaultRaw: String,
        skipPermissions: Bool = false
    ) -> AgentPolicyLevel {
        if skipPermissions {
            return .autonomous
        }
        if let workspaceLevel = workspaceLevel(for: workspace) {
            return effectiveUserFacingLevel(forStored: workspaceLevel, workspace: workspace)
        }
        return effectiveUserFacingLevel(
            forStored: AgentPolicyLevel.normalized(globalDefaultRaw),
            workspace: nil
        )
    }

    static func effectiveUserFacingLevel(
        forStored level: AgentPolicyLevel,
        workspace: Workspace?
    ) -> AgentPolicyLevel {
        guard !level.isPrimaryUserFacing else { return level }
        ensureCustomPolicyPreservesLegacyPreset(level, workspace: workspace)
        return level.userFacingLevel
    }

    static func workspaceLevel(for workspace: Workspace?) -> AgentPolicyLevel? {
        guard let workspace else { return nil }
        let map = workspaceDefaultsMap()
        return map[workspace.id.uuidString].map(AgentPolicyLevel.normalized)
    }

    static func setWorkspaceLevel(_ level: AgentPolicyLevel?, for workspace: Workspace?) {
        guard let workspace else { return }
        var map = workspaceDefaultsMap()
        if let level {
            map[workspace.id.uuidString] = level.rawValue
        } else {
            map.removeValue(forKey: workspace.id.uuidString)
        }
        UserDefaults.standard.set(map, forKey: workspaceDefaultsKey)
    }

    static func workspaceDefaultSource(for workspace: Workspace?) -> AgentPolicyScope {
        workspaceLevel(for: workspace) == nil ? .globalDefault : .workspaceDefault
    }

    static func customPolicy(for workspace: Workspace?) -> AgentPolicy {
        if let workspace,
           let policy = workspaceCustomPoliciesMap()[workspace.id.uuidString] {
            return normalizedCustomPolicy(policy)
        }
        return globalCustomPolicy()
    }

    static func globalCustomPolicy() -> AgentPolicy {
        guard let payload = UserDefaults.standard.string(forKey: globalCustomPolicyKey),
              let policy = decodeCustomPolicy(payload) else {
            return AgentPolicy.preset(.custom)
        }
        return normalizedCustomPolicy(policy)
    }

    static func setCustomPolicy(_ policy: AgentPolicy?, for workspace: Workspace?) {
        if let workspace {
            var map = workspaceCustomPoliciesMap()
            if let policy {
                map[workspace.id.uuidString] = normalizedCustomPolicy(policy)
            } else {
                map.removeValue(forKey: workspace.id.uuidString)
            }
            guard let data = try? JSONEncoder().encode(map),
                  let payload = String(data: data, encoding: .utf8) else {
                return
            }
            UserDefaults.standard.set(payload, forKey: workspaceCustomPoliciesKey)
            return
        }

        if let policy,
           let payload = encodeCustomPolicy(normalizedCustomPolicy(policy)) {
            UserDefaults.standard.set(payload, forKey: globalCustomPolicyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: globalCustomPolicyKey)
        }
    }

    static func resetCustomPolicy(for workspace: Workspace?) {
        setCustomPolicy(nil, for: workspace)
    }

    private static func ensureCustomPolicyPreservesLegacyPreset(_ level: AgentPolicyLevel, workspace: Workspace?) {
        guard AgentPolicyLevel.customPresetCases.contains(level),
              !hasCustomPolicy(for: workspace) else {
            return
        }
        var policy = AgentPolicy.preset(level)
        policy.level = .custom
        setCustomPolicy(policy, for: workspace)
    }

    private static func hasCustomPolicy(for workspace: Workspace?) -> Bool {
        if let workspace {
            return workspaceCustomPoliciesMap()[workspace.id.uuidString] != nil
        }
        return UserDefaults.standard.string(forKey: globalCustomPolicyKey) != nil
    }

    private static func workspaceDefaultsMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: workspaceDefaultsKey) as? [String: String] ?? [:]
    }

    private static func workspaceCustomPoliciesMap() -> [String: AgentPolicy] {
        guard let payload = UserDefaults.standard.string(forKey: workspaceCustomPoliciesKey),
              let data = payload.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: AgentPolicy].self, from: data) else {
            return [:]
        }
        return map.mapValues(normalizedCustomPolicy)
    }

    private static func encodeCustomPolicy(_ policy: AgentPolicy) -> String? {
        guard let data = try? JSONEncoder().encode(policy) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeCustomPolicy(_ payload: String) -> AgentPolicy? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentPolicy.self, from: data)
    }

    private static func normalizedCustomPolicy(_ policy: AgentPolicy) -> AgentPolicy {
        var normalized = policy
        normalized.level = .custom
        return normalized
    }
}
