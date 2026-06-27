import Foundation
import ASTRACore

struct CapabilityPackageResourceSummary: Equatable {
    let skillNames: [String]
    let connectorNames: [String]
    let localToolNames: [String]
    let mcpServerNames: [String]
    let browserAdapterNames: [String]
    let templateNames: [String]
    let prerequisiteNames: [String]

    init(package: PluginPackage) {
        skillNames = Self.uniqueSorted(package.skills.map(\.name))
        connectorNames = Self.uniqueSorted(package.connectors.map(\.name))
        localToolNames = Self.uniqueSorted(package.localTools.map(\.name))
        mcpServerNames = Self.uniqueSorted(package.mcpServers.map { Self.displayName($0.displayName, fallback: $0.id) })
        browserAdapterNames = Self.uniqueSorted(package.browserAdapters)
        templateNames = Self.uniqueSorted(package.templates.map(\.name))
        prerequisiteNames = Self.uniqueSorted(package.prerequisites.map(\.displayName))
    }

    var declaredResourceCount: Int {
        skillNames.count
            + connectorNames.count
            + localToolNames.count
            + mcpServerNames.count
            + browserAdapterNames.count
            + templateNames.count
    }

    var resourceCountsForCacheSignature: [Int] {
        [
            skillNames.count,
            connectorNames.count,
            localToolNames.count,
            mcpServerNames.count,
            templateNames.count,
            browserAdapterNames.count,
            prerequisiteNames.count
        ]
    }

    func contentSummary(separator: String) -> String {
        let parts = [
            countPhrase(skillNames.count, singular: "skill", plural: "skills"),
            countPhrase(connectorNames.count, singular: "connector", plural: "connectors"),
            countPhrase(localToolNames.count, singular: "tool", plural: "tools"),
            countPhrase(mcpServerNames.count, singular: "MCP server", plural: "MCP servers"),
            countPhrase(browserAdapterNames.count, singular: "browser adapter", plural: "browser adapters"),
            countPhrase(templateNames.count, singular: "template", plural: "templates")
        ].compactMap { $0 }

        return parts.isEmpty ? "No declared resources" : parts.joined(separator: separator)
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(
            Set(
                values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countPhrase(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}
