import Foundation
import SwiftData

/// Commit proof saved in the same transaction as a plugin's domain changes.
/// Pending mirror work remains durable even when no credential cleanup is owed.
/// File-operation manifests refer to this ID; they never infer commit from a
/// plugin version or from the existence of an installed library file.
@Model
public final class PluginOperationReceipt {
    @Attribute(.unique) public var id: UUID
    public var formatVersion: Int = 1
    public var kindRawValue: String
    public var pluginIDs: [String]
    public var workspaceIDStrings: [String]
    public var manifestDigest: String?
    public var createdAt: Date
    public var completedAt: Date?

    public enum Kind: String, Codable, Sendable {
        case add, update, remove, configure, accountChange, approval, migration
    }

    public init(id: UUID = UUID(), kind: Kind, pluginIDs: [String], workspaceIDs: [UUID],
                manifestDigest: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.pluginIDs = Array(Set(pluginIDs)).sorted()
        self.workspaceIDStrings = Array(Set(workspaceIDs.map(\.uuidString))).sorted()
        self.manifestDigest = manifestDigest
        self.createdAt = createdAt
        self.completedAt = nil
    }
}
