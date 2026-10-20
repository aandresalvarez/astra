import Foundation

/// The real resolver's accepted account inventory. Optional on older requests;
/// an empty inventory explicitly grants no account. Contains references only,
/// never secret values, and preserves attachment roles independently of live rows.
public struct TaskAccountInventorySnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let account: PluginAccountRecord
        public let skillID: UUID?
        public let parentSkill: SkillLaunchRecord?

        public init(_ connector: Connector, workspaceID: UUID?) {
            account = PluginAccountRecord(connector)
            skillID = connector.skill?.id
            parentSkill = workspaceID.flatMap { id in connector.skill.map { SkillLaunchRecord($0, workspaceID: id) } }
        }
    }

    public let entries: [Entry]
    public let sharedConnectorIDs: [String]

    public init(connectors: [Connector], workspace: Workspace?) {
        entries = connectors.filter { !$0.isDeleted }.map { Entry($0, workspaceID: workspace?.id) }
        sharedConnectorIDs = workspace.map { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs } ?? []
    }
}
