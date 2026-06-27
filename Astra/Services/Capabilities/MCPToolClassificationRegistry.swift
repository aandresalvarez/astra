import Foundation

enum MCPToolAccessLevel: String, Sendable, Equatable {
    case read
    case write
    case destructive

    var requiresNativeApproval: Bool {
        switch self {
        case .read:
            return false
        case .write, .destructive:
            return true
        }
    }
}

enum MCPToolPolicyScope: String, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    case googleDocsRead = "google.docs.read"
    case googleDocsWrite = "google.docs.write"
    case googleDriveRead = "google.drive.read"
    case googleDriveWrite = "google.drive.write"

    var description: String { rawValue }

    static func < (lhs: MCPToolPolicyScope, rhs: MCPToolPolicyScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MCPToolClassification: Sendable, Equatable {
    var serverID: String
    var toolName: String
    var access: MCPToolAccessLevel
    var requiredScopes: Set<MCPToolPolicyScope>

    init(
        serverID: String,
        toolName: String,
        access: MCPToolAccessLevel,
        requiredScopes: Set<MCPToolPolicyScope>
    ) {
        self.serverID = Self.normalized(serverID)
        self.toolName = Self.normalized(toolName)
        self.access = access
        self.requiredScopes = requiredScopes
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct MCPToolClassificationRegistry: Sendable {
    private let classifications: [String: MCPToolClassification]

    init(classifications: [MCPToolClassification]) {
        self.classifications = Dictionary(
            classifications.map { (Self.key(serverID: $0.serverID, toolName: $0.toolName), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func classification(serverID: String, toolName: String) -> MCPToolClassification? {
        classifications[Self.key(serverID: serverID, toolName: toolName)]
    }

    private static func key(serverID: String, toolName: String) -> String {
        "\(MCPToolClassification.normalized(serverID)):\(MCPToolClassification.normalized(toolName))"
    }
}
