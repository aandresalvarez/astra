import Foundation

/// Observation and cancellation are deliberately independent capabilities.
/// A monitoring-only backend advertises `.observe` without implying that ASTRA
/// can stop its work.
public struct ExternalOperationBackendCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let observe = Self(rawValue: 1 << 0)
    public static let cancel = Self(rawValue: 1 << 1)
    public static let monitoringOnly: Self = [.observe]

    public var canObserve: Bool { contains(.observe) }
    public var canCancel: Bool { contains(.cancel) }
}

/// Shared claims are read/observe-only. Exclusive claims are write-capable and
/// conflict with every overlapping active claim, including shared readers.
public enum ExecutionEffectAccess: String, Codable, Hashable, Sendable {
    case shared
    case exclusive

    public var isWriteCapable: Bool { self == .exclusive }
}

/// Stable, provider-neutral description of the resources an execution or
/// external operation can affect. Callers must use `.computeOnly` explicitly;
/// an absent or unknown declaration never silently means "no side effects."
public enum ExecutionEffectScope: Codable, Hashable, Sendable {
    /// `repositoryID == nil` claims the entire workspace.
    case workspaceRepository(workspaceID: String, repositoryID: String?)
    /// Paths are POSIX paths within a stable remote-host identity.
    case remotePath(hostID: String, path: String)
    /// `datasetID == nil` claims the entire database.
    case datasetDatabase(dataSourceID: String, databaseID: String, datasetID: String?)
    case cloudResource(providerID: String, resourceID: String)
    case computeOnly
    /// The caller knows side effects may exist but cannot bound their scope.
    case unknown

    public var isComputeOnly: Bool {
        if case .computeOnly = self { return true }
        return false
    }

    public var isKnownAndWellFormed: Bool {
        switch self {
        case .workspaceRepository(let workspaceID, let repositoryID):
            return Self.identifier(workspaceID) != nil
                && repositoryID.map { Self.identifier($0) != nil } ?? true
        case .remotePath(let hostID, let path):
            return Self.identifier(hostID) != nil && Self.normalizedAbsolutePath(path) != nil
        case .datasetDatabase(let dataSourceID, let databaseID, let datasetID):
            return Self.identifier(dataSourceID) != nil
                && Self.identifier(databaseID) != nil
                && (datasetID.map { Self.identifier($0) != nil } ?? true)
        case .cloudResource(let providerID, let resourceID):
            return Self.identifier(providerID) != nil && Self.identifier(resourceID) != nil
        case .computeOnly:
            return true
        case .unknown:
            return false
        }
    }

    /// Conservative, symmetric overlap relation. Invalid/unknown declarations
    /// overlap every effectful scope; explicit compute-only work overlaps none.
    public func overlaps(_ other: Self) -> Bool {
        if isComputeOnly || other.isComputeOnly { return false }
        guard isKnownAndWellFormed, other.isKnownAndWellFormed else { return true }

        switch (self, other) {
        case let (
            .workspaceRepository(lhsWorkspace, lhsRepository),
            .workspaceRepository(rhsWorkspace, rhsRepository)
        ):
            guard Self.identifier(lhsWorkspace) == Self.identifier(rhsWorkspace) else { return false }
            guard let lhsRepository, let rhsRepository else { return true }
            return Self.identifier(lhsRepository) == Self.identifier(rhsRepository)

        case let (.remotePath(lhsHost, lhsPath), .remotePath(rhsHost, rhsPath)):
            guard Self.identifier(lhsHost) == Self.identifier(rhsHost),
                  let lhs = Self.normalizedAbsolutePath(lhsPath),
                  let rhs = Self.normalizedAbsolutePath(rhsPath) else {
                return false
            }
            return Self.path(lhs, containsOrEquals: rhs) || Self.path(rhs, containsOrEquals: lhs)

        case let (
            .datasetDatabase(lhsSource, lhsDatabase, lhsDataset),
            .datasetDatabase(rhsSource, rhsDatabase, rhsDataset)
        ):
            guard Self.identifier(lhsSource) == Self.identifier(rhsSource),
                  Self.identifier(lhsDatabase) == Self.identifier(rhsDatabase) else {
                return false
            }
            guard let lhsDataset, let rhsDataset else { return true }
            return Self.identifier(lhsDataset) == Self.identifier(rhsDataset)

        case let (
            .cloudResource(lhsProvider, lhsResource),
            .cloudResource(rhsProvider, rhsResource)
        ):
            return Self.identifier(lhsProvider) == Self.identifier(rhsProvider)
                && Self.identifier(lhsResource) == Self.identifier(rhsResource)

        default:
            return false
        }
    }

    private static func identifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        var components: [Substring] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func path(_ ancestor: String, containsOrEquals descendant: String) -> Bool {
        ancestor == descendant || ancestor == "/" || descendant.hasPrefix(ancestor + "/")
    }
}

public struct ExecutionEffectClaim: Codable, Hashable, Sendable {
    public let scope: ExecutionEffectScope
    public let access: ExecutionEffectAccess

    public init(scope: ExecutionEffectScope, access: ExecutionEffectAccess) {
        self.scope = scope
        self.access = access
    }

    public static let computeOnly = ExecutionEffectClaim(scope: .computeOnly, access: .shared)

    public var isWriteCapable: Bool { access.isWriteCapable }
    public var isKnownAndWellFormed: Bool { scope.isKnownAndWellFormed }

    public func conflicts(with other: Self) -> Bool {
        guard scope.overlaps(other.scope) else { return false }
        return access == .exclusive || other.access == .exclusive
    }
}
