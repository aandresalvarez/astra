import Foundation
import SwiftData
import ASTRAModels

/// Evidence captured from the local owner before an explicit replacement.
/// A selected file cannot grant itself access to a local credential identity.
public struct WorkspaceReplacementCredentialIdentity {
    private let workspaceID: String
    private let workspacePath: String
    private let connectors: [String: Data]
    private let skills: [String: Data]
    private let dependencies: Data

    @MainActor
    public init?(workspace: Workspace, modelContext: ModelContext) {
        guard workspace.modelContext === modelContext,
              let exported = WorkspaceConfigManager.export(workspace: workspace, modelContext: modelContext),
              let dependencies = Self.dependencyFingerprint(exported) else { return nil }
        workspaceID = workspace.id.uuidString
        workspacePath = workspace.primaryPath
        let connectorIDs = Set(workspace.connectors.filter { !$0.isGlobal && $0.workspace?.id == workspace.id }.map { $0.id.uuidString })
        let skillIDs = Set(workspace.skills.filter { !$0.isGlobal && $0.workspace?.id == workspace.id }.map { $0.id.uuidString })
        connectors = Self.records(exported.connectors ?? [], id: { $0.id }, ownedIDs: connectorIDs)
        skills = Self.records(exported.skills, id: { $0.id }, ownedIDs: skillIDs)
        self.dependencies = dependencies
    }

    func connectorIDs(in config: WorkspaceConfigManager.WorkspaceConfig) -> Set<String> {
        guard owns(config) else { return [] }
        return Self.matches(config.connectors ?? [], id: { $0.id }, against: connectors)
    }

    func skillIDs(in config: WorkspaceConfigManager.WorkspaceConfig) -> Set<String> {
        guard owns(config), Self.dependencyFingerprint(config) == dependencies else { return [] }
        return Self.matches(config.skills, id: { $0.id }, against: skills)
    }

    private func owns(_ config: WorkspaceConfigManager.WorkspaceConfig) -> Bool {
        config.id == workspaceID || config.primaryPath == workspacePath
    }

    private static func records<T: Encodable>(_ rows: [T], id: (T) -> String?, ownedIDs: Set<String>) -> [String: Data] {
        let groups = Dictionary(grouping: rows, by: id)
        var result: [String: Data] = [:]
        for (key, values) in groups {
            guard let key, ownedIDs.contains(key), values.count == 1,
                  let value = values.first, let data = fingerprint(value) else { continue }
            result[key] = data
        }
        return result
    }

    private static func matches<T: Encodable>(_ rows: [T], id: (T) -> String?, against saved: [String: Data]) -> Set<String> {
        let groups = Dictionary(grouping: rows, by: id)
        return Set(groups.compactMap { key, values in
            guard let key, values.count == 1, let value = values.first,
                  let expected = saved[key], fingerprint(value) == expected else { return nil }
            return key
        })
    }

    private static func dependencyFingerprint(_ config: WorkspaceConfigManager.WorkspaceConfig) -> Data? {
        // A skill's unchanged ID cannot carry secrets into a changed tool or account.
        let rows = (config.connectors ?? []).compactMap { fingerprint($0) }
            + (config.localTools ?? []).compactMap { fingerprint($0) }
        guard rows.count == (config.connectors ?? []).count + (config.localTools ?? []).count else { return nil }
        return try? JSONEncoder().encode(rows.sorted { $0.lexicographicallyPrecedes($1) })
    }

    private static func fingerprint<T: Encodable>(_ value: T) -> Data? {
        guard let encoded = try? JSONEncoder().encode(value),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return nil }
        // Portable ISO dates lose fractional seconds; they convey no authority.
        object.removeValue(forKey: "createdAt")
        object.removeValue(forKey: "updatedAt")
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
