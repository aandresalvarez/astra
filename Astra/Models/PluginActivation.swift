import CryptoKit
import Foundation
import SwiftData

/// One installed plugin turned on (or kept off) in one workspace.
///
/// The plugin's definition lives in the capability library; this record owns
/// only what belongs to the workspace: whether the plugin is on, the version
/// and digest it was added at, its per-workspace settings, the components the
/// person replaced with an authored row, and which accounts each connector
/// component uses. The runtime derives the plugin's skills and tools from the
/// library entry plus this record (`PluginRuntimeProjection`), so no other row
/// carries a copy of these facts.
///
/// Every write goes through `WorkspaceCapabilityActivation`, which bumps
/// `revision`; nothing else writes this model.
@Model
public final class PluginActivation {
    public var id: UUID
    public var pluginID: String
    public var isEnabled: Bool
    /// The plugin version and library digest this workspace last accepted.
    /// Empty when unknown (a plugin whose library entry is missing).
    public var recordedVersion: String
    public var recordedDigest: String
    /// Non-secret settings keyed `componentID#KEY` (`settingKey`), paired by
    /// index. An empty value is an explicit setting, not an absent one.
    /// Secret values are in the Keychain under the projected component's ID.
    public var configKeys: [String]
    public var configValues: [String]
    /// The secret settings (`componentID#KEY`) written to the Keychain, so a
    /// key a later definition drops can be cleared.
    public var secretSettingKeys: [String]
    /// Components the person replaced with an authored row, and that row's
    /// UUID string (paired by index; empty when the row is gone). The
    /// projection skips the component and brings in the row instead, so
    /// nothing is duplicated and nothing is found by name.
    public var overriddenComponentIDs: [String]
    public var overridingRowIDs: [String]
    /// The components of the definition this activation was last reconciled
    /// against. An Update compares them with the new definition: one that is
    /// gone (and not taken over through `replaces`) has its settings,
    /// accounts and secrets released. Seeded by Add and the migration.
    public var knownComponentIDs: [String]
    /// Mixed into the projected components' IDs (and so their Keychain
    /// namespaces) when not empty. A validated import of a workspace file
    /// gets a fresh one, so a file imported over a workspace under its ID
    /// never reads the secrets that workspace's activation stored.
    public var namespaceSeed: String
    /// Each plugin template row's content digest as the last sync wrote it,
    /// `componentID#digest`. A stamped row whose content no longer matches
    /// was edited by the person: a sync keeps it as their own row
    /// (`PluginTemplateSync`) instead of overwriting it.
    public var templateDigests: [String] = []
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public var workspace: Workspace?

    /// The digest `templateDigests` records for one template component.
    public func templateDigest(forComponent componentID: String) -> String? {
        templateDigests.lazy
            .compactMap { entry -> String? in
                guard let separator = entry.lastIndex(of: "#"), entry[..<separator] == componentID else { return nil }
                return String(entry[entry.index(after: separator)...])
            }
            .first
    }

    @Relationship(deleteRule: .cascade, inverse: \AccountBinding.activation)
    public var bindings: [AccountBinding] = []

    public init(
        id: UUID = UUID(),
        pluginID: String,
        isEnabled: Bool = true,
        recordedVersion: String = "",
        recordedDigest: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pluginID = pluginID
        self.isEnabled = isEnabled
        self.recordedVersion = recordedVersion
        self.recordedDigest = recordedDigest
        self.configKeys = []
        self.configValues = []
        self.overriddenComponentIDs = []
        self.overridingRowIDs = []
        self.secretSettingKeys = []
        self.knownComponentIDs = []
        self.namespaceSeed = ""
        self.templateDigests = []
        self.revision = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// The ID of a component's projected skill or tool, which also names
    /// its Keychain namespace: a name-based UUID (version 5 layout) over the
    /// workspace, plugin and component IDs, plus the activation's namespace
    /// seed when it has one.
    public static func projectedID(workspaceID: UUID, pluginID: String, componentID: String, seed: String = "") -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("astra.plugin-component.v2|".utf8))
        hasher.update(data: Data(workspaceID.uuidString.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(pluginID.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(componentID.utf8))
        if !seed.isEmpty {
            hasher.update(data: Data("|".utf8))
            hasher.update(data: Data(seed.utf8))
        }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// A setting's key. Setting keys (environment variable names) never
    /// contain `#` (`CapabilityPackageValidator` rejects a package declaring
    /// one), so the last `#` splits the pair however the component is named
    /// (a component ID may contain `.` or `#`).
    public static func settingKey(componentID: String, key: String) -> String {
        "\(componentID)#\(key)"
    }

    /// The component a setting key belongs to.
    public static func componentID(ofSettingKey settingKey: String) -> String? {
        settingKey.lastIndex(of: "#").map { String(settingKey[..<$0]) }
    }

    /// Settings keyed `componentID#KEY`.
    public var configuration: [String: String] {
        var values: [String: String] = [:]
        for (index, key) in configKeys.enumerated() where index < configValues.count {
            values[key] = configValues[index]
        }
        return values
    }

    /// Settings for one component, keyed by the bare `KEY`.
    public func configuration(forComponent componentID: String) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in configuration where Self.componentID(ofSettingKey: key) == componentID {
            values[String(key.dropFirst(componentID.count + 1))] = value
        }
        return values
    }

    /// The authored row that replaced `componentID`, if one is recorded.
    public func overridingRowID(forComponent componentID: String) -> UUID? {
        guard let index = overriddenComponentIDs.firstIndex(of: componentID),
              index < overridingRowIDs.count else { return nil }
        return UUID(uuidString: overridingRowIDs[index])
    }

    /// The accounts bound to one connector component, default first.
    public func accounts(forComponent componentID: String) -> [Connector] {
        bindings
            .filter { $0.componentID == componentID }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.createdAt < rhs.createdAt
            }
            .compactMap(\.account)
    }
}

/// A connector component of an activation bound to the connector row that
/// serves as its account. A component may bind several accounts (two Jira
/// sites); one is the default. Deleting the account deletes its bindings, so
/// no activation keeps a dangling reference.
@Model
public final class AccountBinding {
    public var id: UUID
    public var componentID: String
    public var isDefault: Bool
    public var createdAt: Date

    public var activation: PluginActivation?
    public var account: Connector?

    public init(
        id: UUID = UUID(),
        componentID: String,
        isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.componentID = componentID
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}
