import Foundation
import ASTRACore
import ASTRAModels

enum CapabilityResourceComponentKind: String {
    case skill
    case connector
    case localTool = "local_tool"
    case template
}

enum CapabilityResourceOrigin {
    static func componentID(for skill: PluginSkill) -> String {
        "skill:\(normalized(skill.name))"
    }

    static func componentID(for connector: PluginConnector) -> String {
        "connector:\(normalized(connector.serviceType)):\(normalized(connector.name))"
    }

    static func componentID(for tool: PluginLocalTool) -> String {
        "tool:\(normalized(tool.toolType)):\(normalized(tool.command)):\(normalized(tool.name))"
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
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
