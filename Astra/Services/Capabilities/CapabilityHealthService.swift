import Foundation
import ASTRACore

struct CapabilityHealthIssue: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case missingBinary = "missing_binary"
        case unauthenticated
        case unresponsive
    }

    let packageID: String
    let packageName: String
    let kind: Kind
    let resourceName: String
    let message: String

    var id: String {
        "\(packageID):\(kind.rawValue):\(resourceName)"
    }
}

enum CapabilityHealthService {
    static func prerequisiteStatuses(
        for package: PluginPackage,
        cache: PreflightCache
    ) async -> [String: HealthStatus] {
        var statuses: [String: HealthStatus] = [:]
        for prerequisite in package.prerequisites {
            statuses[prerequisite.id] = await cache.status(for: prerequisite)
        }
        return statuses
    }

    static func prerequisiteIssues(
        for package: PluginPackage,
        statuses: [String: HealthStatus]
    ) -> [CapabilityHealthIssue] {
        package.prerequisites.compactMap { prerequisite in
            guard let status = statuses[prerequisite.id] else { return nil }
            return issue(for: prerequisite, status: status, package: package)
        }
    }

    static func readinessMessages(
        for package: PluginPackage,
        statuses: [String: HealthStatus]
    ) -> [String] {
        prerequisiteIssues(for: package, statuses: statuses).map(\.message)
            + CapabilityMCPReadinessService.readinessMessages(for: package, prerequisiteStatuses: statuses)
    }

    private static func issue(
        for prerequisite: CLIPrerequisite,
        status: HealthStatus,
        package: PluginPackage
    ) -> CapabilityHealthIssue? {
        switch status {
        case .healthy:
            return nil
        case .missingBinary:
            return CapabilityHealthIssue(
                packageID: package.id,
                packageName: package.name,
                kind: .missingBinary,
                resourceName: prerequisite.displayName,
                message: "\(prerequisite.displayName): not installed. \(prerequisite.installHint)"
            )
        case .unauthenticated(let detail):
            return CapabilityHealthIssue(
                packageID: package.id,
                packageName: package.name,
                kind: .unauthenticated,
                resourceName: prerequisite.displayName,
                message: "\(prerequisite.displayName): needs login. \(detail). \(prerequisite.authHint ?? "")"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .unresponsive(let detail):
            let hint = prerequisite.authHint ?? prerequisite.installHint
            return CapabilityHealthIssue(
                packageID: package.id,
                packageName: package.name,
                kind: .unresponsive,
                resourceName: prerequisite.displayName,
                message: "\(prerequisite.displayName): did not respond. \(detail). \(hint)"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
