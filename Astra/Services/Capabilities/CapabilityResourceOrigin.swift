import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum CapabilityResourceComponentKind: String {
    case skill
    case connector
    case localTool = "local_tool"
    case template
}

enum CapabilityResourceOrigin {
    static func componentID(for skill: PluginSkill) -> String {
        "skill:\(normalized(skill.id ?? skill.name))"
    }

    static func componentID(for connector: PluginConnector) -> String {
        "connector:\(normalized(connector.serviceType)):\(normalized(connector.id ?? connector.name))"
    }

    /// The start every component ID of a connector of `serviceType` has.
    static func connectorPrefix(serviceType: String) -> String {
        "connector:\(normalized(serviceType)):"
    }

    static func componentID(for tool: PluginLocalTool) -> String {
        if let id = tool.id { return "tool:\(normalized(id))" }
        return "tool:\(normalized(tool.toolType)):\(normalized(tool.command)):\(normalized(tool.name))"
    }

    /// The component identities `replaces` names, in the same form as
    /// `componentID(for:)`: a bare value is that kind's `id`.
    static func replacedComponentIDs(for skill: PluginSkill) -> [String] {
        (skill.replaces ?? []).map { $0.contains(":") ? canonical($0) : "skill:\(normalized($0))" }
    }

    static func replacedComponentIDs(for connector: PluginConnector) -> [String] {
        (connector.replaces ?? []).map {
            $0.contains(":") ? canonical($0) : "connector:\(normalized(connector.serviceType)):\(normalized($0))"
        }
    }

    static func replacedComponentIDs(for tool: PluginLocalTool) -> [String] {
        (tool.replaces ?? []).map { $0.contains(":") ? canonical($0) : "tool:\(normalized($0))" }
    }

    /// A full identity (`skill:Old Agent`, `connector:Jira:Old`) in the form
    /// `componentID(for:)` produces: every part after the kind normalized,
    /// so a predecessor is matched however its author spelled it.
    static func canonical(_ identity: String) -> String {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return identity }
        return ([kind.trimmingCharacters(in: .whitespaces).lowercased()] + parts.dropFirst().map(normalized))
            .joined(separator: ":")
    }

    static func componentID(for template: PluginTemplate) -> String {
        "template:\(normalized(template.name))"
    }

    static func stamp(
        _ skill: Skill,
        package: PluginPackage,
        componentID: String
    ) {
        stamp(
            package: package,
            componentID: componentID,
            componentKind: .skill,
            set: { applyOrigin($0, to: skill) }
        )
    }

    static func stamp(
        _ connector: Connector,
        package: PluginPackage,
        componentID: String
    ) {
        stamp(
            package: package,
            componentID: componentID,
            componentKind: .connector,
            set: { applyOrigin($0, to: connector) }
        )
    }

    static func stamp(
        _ tool: LocalTool,
        package: PluginPackage,
        componentID: String
    ) {
        stamp(
            package: package,
            componentID: componentID,
            componentKind: .localTool,
            set: { applyOrigin($0, to: tool) }
        )
    }

    static func stamp(
        _ template: TaskTemplate,
        package: PluginPackage,
        componentID: String
    ) {
        stamp(
            package: package,
            componentID: componentID,
            componentKind: .template,
            set: { applyOrigin($0, to: template) }
        )
    }

    static func isOwnedBy(_ skill: Skill, packageID: String) -> Bool {
        skill.originPackageID == packageID
    }

    static func isOwnedBy(_ connector: Connector, packageID: String) -> Bool {
        connector.originPackageID == packageID
    }

    static func isOwnedBy(_ tool: LocalTool, packageID: String) -> Bool {
        tool.originPackageID == packageID
    }

    static func isOwnedBy(_ template: TaskTemplate, packageID: String) -> Bool {
        template.originPackageID == packageID
    }

    static func hasOrigin(_ skill: Skill) -> Bool {
        !(skill.originPackageID ?? "").isEmpty
    }

    static func hasOrigin(_ connector: Connector) -> Bool {
        !(connector.originPackageID ?? "").isEmpty
    }

    static func hasOrigin(_ tool: LocalTool) -> Bool {
        !(tool.originPackageID ?? "").isEmpty
    }

    static func hasOrigin(_ template: TaskTemplate) -> Bool {
        !(template.originPackageID ?? "").isEmpty
    }

    /// Clears a plugin's origin stamp from an account it leaves behind. The
    /// stamp also names a shared Keychain namespace, so credentials only
    /// there are first copied into the row's own (which loads first); one the
    /// copy can't reach keeps the stamp rather than be stranded (false).
    @MainActor
    @discardableResult
    static func releaseProvenance(of account: Connector) -> Bool {
        // A published private generation is independent of provenance. Never
        // backfill its values into historical shared aliases or the row ID.
        if account.credentialNamespaceID == nil {
            KeychainService.synchronizeConnectorCredentialNamespaces(connector: account)
            let stranded = account.credentialKeys.contains { key in
                KeychainService.load(key: key, connectorID: account.id) == nil
                    && KeychainService.load(key: key, connector: account) != nil
            }
            guard !stranded else { return false }
        }
        account.originPackageID = nil
        account.originPackageVersion = nil
        account.originComponentID = nil
        account.originComponentKind = nil
        account.originSourceKind = nil
        account.updatedAt = Date()
        return true
    }

    private struct OriginFields {
        var packageID: String
        var packageVersion: String
        var componentID: String
        var componentKind: String
        var sourceKind: String
    }

    private static func stamp(
        package: PluginPackage,
        componentID: String,
        componentKind: CapabilityResourceComponentKind,
        set: (OriginFields) -> Void
    ) {
        set(OriginFields(
            packageID: package.id,
            packageVersion: package.version,
            componentID: componentID,
            componentKind: componentKind.rawValue,
            sourceKind: package.sourceMetadata?.kind ?? "local"
        ))
    }

    private static func applyOrigin(_ origin: OriginFields, to skill: Skill) {
        guard shouldApply(origin, existingPackageID: skill.originPackageID) else { return }
        skill.originPackageID = origin.packageID
        skill.originPackageVersion = origin.packageVersion
        skill.originComponentID = origin.componentID
        skill.originComponentKind = origin.componentKind
        skill.originSourceKind = origin.sourceKind
    }

    private static func applyOrigin(_ origin: OriginFields, to connector: Connector) {
        guard shouldApply(origin, existingPackageID: connector.originPackageID) else { return }
        connector.originPackageID = origin.packageID
        connector.originPackageVersion = origin.packageVersion
        connector.originComponentID = origin.componentID
        connector.originComponentKind = origin.componentKind
        connector.originSourceKind = origin.sourceKind
    }

    private static func applyOrigin(_ origin: OriginFields, to tool: LocalTool) {
        guard shouldApply(origin, existingPackageID: tool.originPackageID) else { return }
        tool.originPackageID = origin.packageID
        tool.originPackageVersion = origin.packageVersion
        tool.originComponentID = origin.componentID
        tool.originComponentKind = origin.componentKind
        tool.originSourceKind = origin.sourceKind
    }

    private static func applyOrigin(_ origin: OriginFields, to template: TaskTemplate) {
        guard shouldApply(origin, existingPackageID: template.originPackageID) else { return }
        template.originPackageID = origin.packageID
        template.originPackageVersion = origin.packageVersion
        template.originComponentID = origin.componentID
        template.originComponentKind = origin.componentKind
        template.originSourceKind = origin.sourceKind
    }

    private static func shouldApply(_ origin: OriginFields, existingPackageID: String?) -> Bool {
        let existing = existingPackageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let applies = existing.isEmpty || existing == origin.packageID
        if !applies {
            // Declining is correct (the resource keeps its original owner),
            // but contested ownership matters for later uninstall debugging.
            AppLogger.audit(.capabilityEnableStarted, category: "Capabilities", fields: [
                "source": "resource_origin_stamp",
                "result": "skipped_contested_ownership",
                "owning_package_id": existing,
                "requesting_package_id": origin.packageID,
                "component_id": origin.componentID
            ], level: .warning)
        }
        return applies
    }

    private static func normalized(_ value: String) -> String {
        PluginComponent.defaultID(forName: value)
    }
}
