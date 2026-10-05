import Foundation

/// Accepted filesystem authority. Launch copies and manifests are projections
/// of this value; they must never resolve a larger scope from live settings.
public struct TaskExecutionResourceScope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Role: String, Codable, Sendable {
        case execution
        case additionalFolder
        case taskStorage
        case input
        case gitMetadata
        case environmentMount
        case isolationSource
    }

    public struct Resource: Codable, Equatable, Sendable {
        public let path: String
        public let canonicalPath: String
        public let access: TaskExecutionResourceAccess
        public let role: Role

        public init(path: String, access: TaskExecutionResourceAccess, role: Role) {
            self.path = (path as NSString).expandingTildeInPath
            canonicalPath = TaskExecutionResourceScope.canonicalPath(path)
            self.access = access
            self.role = role
        }
    }

    public let version: Int
    public let workingDirectory: String
    public let workspacePath: String
    public let resources: [Resource]
    public let replacedCheckoutPaths: [String]

    public init(
        workingDirectory: String,
        workspacePath: String,
        resources: [Resource],
        replacedCheckoutPaths: [String] = []
    ) {
        version = Self.currentVersion
        self.workingDirectory = workingDirectory
        self.workspacePath = workspacePath
        self.resources = resources
        self.replacedCheckoutPaths = replacedCheckoutPaths
    }

    public var claims: [TaskExecutionResourceClaim] {
        var claims: [TaskExecutionResourceClaim] = []
        for resource in resources {
            let claim: TaskExecutionResourceClaim = switch resource.role {
            case .gitMetadata:
                TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: resource.canonicalPath, access: resource.access)
            case .taskStorage:
                TaskExecutionResourceClaim(kind: .taskStorage, key: resource.canonicalPath, access: resource.access)
            default:
                TaskExecutionResourceClaim(kind: .workspace, key: resource.canonicalPath, access: resource.access)
            }
            if let index = claims.firstIndex(where: { $0.kind == claim.kind && $0.key == claim.key }) {
                if claim.access == .exclusive { claims[index] = claim }
            } else {
                claims.append(claim)
            }
        }
        return claims
    }

    public var executionAccess: TaskExecutionResourceAccess {
        resources.first { $0.role == .execution }?.access ?? .exclusive
    }

    public var providerWritableFolders: [String] {
        resources.filter {
            $0.access == .exclusive && [.execution, .additionalFolder, .taskStorage].contains($0.role)
        }.map(\.path)
    }

    public var isValid: Bool {
        version == Self.currentVersion
            && resources.allSatisfy {
                !$0.path.isEmpty && $0.path.hasPrefix("/")
                    && $0.path.rangeOfCharacter(from: .newlines) == nil
                    && $0.canonicalPath == Self.canonicalPath($0.path)
            }
            && replacedCheckoutPaths.allSatisfy {
                $0.hasPrefix("/") && $0.rangeOfCharacter(from: .newlines) == nil
            }
            && (workingDirectory.isEmpty || resources.contains {
                $0.role == .execution && $0.canonicalPath == Self.canonicalPath(workingDirectory)
            })
    }

    public func coversWrite(to path: String) -> Bool {
        let canonical = Self.canonicalPath(path)
        if resources.contains(where: {
            $0.role == .input && Self.contains($0.canonicalPath, canonical)
        }) { return false }
        let matches = resources.filter { Self.contains($0.canonicalPath, canonical) }
        guard let length = matches.map(\.canonicalPath.count).max() else { return false }
        return matches.filter { $0.canonicalPath.count == length }.allSatisfy { $0.access == .exclusive }
    }

    public var folderGuidance: String {
        let folders = resources.filter { $0.role != .gitMetadata && $0.role != .isolationSource }
            .map { "- \($0.path) (\($0.access == .exclusive ? "read-write" : "read-only"); \($0.role.rawValue))" }
            .joined(separator: "\n")
        return "Accepted execution folders:\n\(folders)\nOnly these folders are granted for this turn. Additional access requires a newly admitted request."
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func contains(_ root: String, _ path: String) -> Bool {
        root == path || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
