import CoreData
import Foundation

/// Durable, non-SwiftData compatibility information written beside each store.
/// Startup reads this before constructing a writable ModelContainer so an older
/// binary never has to infer compatibility from SwiftData's lossy error wrapper.
public struct PersistentStoreCompatibilityMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let minimumReaderSchemaVersion: Int
    public let channel: String
    public let appVersion: String
    public let appBuild: String
    public let gitCommit: String
    public let bundlePath: String
    public let recordedAt: Date

    public init(
        schemaVersion: Int,
        minimumReaderSchemaVersion: Int,
        channel: String,
        appVersion: String,
        appBuild: String,
        gitCommit: String,
        bundlePath: String,
        recordedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.minimumReaderSchemaVersion = minimumReaderSchemaVersion
        self.channel = channel
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.gitCommit = gitCommit
        self.bundlePath = bundlePath
        self.recordedAt = recordedAt
    }
}

public enum PersistentStoreCompatibilityAssessment: Equatable, Sendable {
    case compatible(storeSchemaVersion: Int?)
    case requiresNewerReader(requiredSchemaVersion: Int)
    case unknown
}

public enum PersistentStoreKnownShape: Equatable, Sendable {
    case runtimeSelectionOnlyV12
    case feedbackOnlyV12
    case productionV12
    case externalOperationV15
    case externalOperationInitialV15
    case other

    /// Stable value for persisted migration records and structured audit logs.
    public var auditValue: String {
        switch self {
        case .runtimeSelectionOnlyV12:
            return "runtime_selection_only_v12"
        case .feedbackOnlyV12:
            return "feedback_only_v12"
        case .productionV12:
            return "production_v12"
        case .externalOperationV15:
            return "external_operation_v15"
        case .externalOperationInitialV15:
            return "external_operation_initial_v15"
        case .other:
            return "other"
        }
    }

    /// The schema version identifier the shape's stores carry on disk.
    public var sourceSchemaVersion: Int? {
        switch self {
        case .runtimeSelectionOnlyV12, .feedbackOnlyV12, .productionV12:
            return 12
        case .externalOperationV15, .externalOperationInitialV15:
            return 15
        case .other:
            return nil
        }
    }
}

/// Identifies the colliding store shapes that reached disk under an already
/// claimed Core Data version identifier: the three 12.0.0 shapes and the two
/// external-operation 15.0.0 sub-shapes. Entity names are only a routing
/// hint: the dedicated migration plan still verifies every model hash before
/// it can open a copy.
public enum PersistentStoreModelShapeService {
    private static let v12Identifier = "12.0.0"
    private static let v15Identifier = "15.0.0"
    // These checksums were captured from sanitized stores produced by the
    // actual historical builds. Entity names alone cannot distinguish the two
    // incompatible 17-entity V12 models.
    private static let feedbackOnlyV12Checksum = "hTf3SZACvFlI82r2SNAsEWesdpFXcA6hSkiPUnH0Erk="
    private static let productionV12Checksum = "aRvGJIZNZ/lwoob9yJ52572ipBYvz/ipXn6a6nJO6oU="
    // The abandoned external-operation branch reused 15.0.0 for a schema
    // whose extra entity is TaskExternalOperation instead of the canonical
    // TaskTurnRequest, and its Dev builds wrote two sub-shapes because
    // launchResourceKey was added mid-branch. The initial (pre-
    // launchResourceKey) checksum is the one observed on disk and documented
    // in SchemaVersionTests' canonical-V15 pin; both frozen schemas are
    // pinned to these values there.
    private static let externalOperationV15Checksum = "Y4VRug2MsVnb+dlybKvYqRGpwBl3EHlI5Ukk3Eqttr8="
    private static let externalOperationInitialV15Checksum = "fjNnIAoVBrprvCS0R9NHWeJKEu/l0I7XjMZHs9trXEk="
    private static let runtimeSelectionOnlyV12Entities: Set<String> = [
        "Workspace",
        "AgentTask",
        "TaskRun",
        "TaskEvent",
        "Artifact",
        "Skill",
        "Connector",
        "LocalTool",
        "TaskTemplate",
        "TaskSchedule",
        "WorkspaceApp",
        "WorkspaceAppRun",
        "WorkspaceAppRunEvent",
        "WorkspaceAppDependencyBinding",
        "WorkspaceAppAutomationState",
        "GoogleOAuthAccountProfile"
    ]

    public static func shape(
        ofStoreAt storeURL: URL,
        persistentStoreMetadata: [String: Any]? = nil
    ) throws -> PersistentStoreKnownShape {
        let metadata = try persistentStoreMetadata ?? NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        return shape(from: metadata)
    }

    private static var externalOperationV15Entities: Set<String> {
        runtimeSelectionOnlyV12Entities.union([
            "FeedbackReport",
            "PersistentStoreMigrationRecord",
            "TaskExternalOperation"
        ])
    }

    public static func shape(from metadata: [String: Any]) -> PersistentStoreKnownShape {
        let identifiers = versionIdentifiers(from: metadata)
        guard let entities = entityNames(from: metadata) else {
            return .other
        }
        if identifiers.contains(v12Identifier) {
            if entities == runtimeSelectionOnlyV12Entities {
                return .runtimeSelectionOnlyV12
            }
            if entities == runtimeSelectionOnlyV12Entities.union(["FeedbackReport"]) {
                switch modelChecksum(from: metadata) {
                case feedbackOnlyV12Checksum:
                    return .feedbackOnlyV12
                case productionV12Checksum:
                    return .productionV12
                default:
                    return .other
                }
            }
            return .other
        }
        if identifiers.contains(v15Identifier), entities == externalOperationV15Entities {
            // A canonical V15 store carries TaskTurnRequest, never
            // TaskExternalOperation, so the entity set alone separates the
            // branches; the checksum additionally pins WHICH sub-shape wrote
            // the store so recovery opens it with the exact frozen model.
            switch modelChecksum(from: metadata) {
            case externalOperationV15Checksum:
                return .externalOperationV15
            case externalOperationInitialV15Checksum:
                return .externalOperationInitialV15
            default:
                return .other
            }
        }
        return .other
    }

    private static func versionIdentifiers(from metadata: [String: Any]) -> Set<String> {
        let value = metadata[NSStoreModelVersionIdentifiersKey]
        if let strings = value as? [String] { return Set(strings) }
        if let strings = value as? Set<String> { return strings }
        if let string = value as? String { return [string] }
        return []
    }

    private static func entityNames(from metadata: [String: Any]) -> Set<String>? {
        let value = metadata["NSStoreModelVersionHashes"]
        if let hashes = value as? [String: Any] {
            return Set(hashes.keys)
        }
        if let hashes = value as? NSDictionary {
            return Set(hashes.allKeys.compactMap { $0 as? String })
        }
        return nil
    }

    private static func modelChecksum(from metadata: [String: Any]) -> String? {
        metadata["NSStoreModelVersionChecksumKey"] as? String
    }
}

public enum PersistentStoreCompatibilityService {
    public static func metadataURL(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + ".astra-compatibility.json")
    }

    public static func readMetadata(
        for storeURL: URL,
        fileManager: FileManager = .default
    ) -> PersistentStoreCompatibilityMetadata? {
        let url = metadataURL(for: storeURL)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistentStoreCompatibilityMetadata.self, from: data)
    }

    public static func writeMetadata(
        _ metadata: PersistentStoreCompatibilityMetadata,
        for storeURL: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: storeURL), options: .atomic)
    }

    public static func assess(
        storeURL: URL,
        latestSupportedSchemaVersion: Int,
        fileManager: FileManager = .default,
        persistentStoreMetadata: ([String: Any])? = nil
    ) -> PersistentStoreCompatibilityAssessment {
        // A sidecar describes a particular store file, not the vacant path it
        // once occupied. Ignoring an orphan allows SwiftData to create a fresh
        // store instead of wedging startup on stale compatibility metadata.
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return .unknown
        }
        if let metadata = readMetadata(for: storeURL, fileManager: fileManager) {
            if metadata.minimumReaderSchemaVersion > latestSupportedSchemaVersion {
                return .requiresNewerReader(requiredSchemaVersion: metadata.minimumReaderSchemaVersion)
            }
            return .compatible(storeSchemaVersion: metadata.schemaVersion)
        }

        // Older stores predate ASTRA's sidecar. Core Data exposes the versioned
        // schema identifier read-only, without attaching a writable store.
        let rawMetadata: [String: Any]
        if let persistentStoreMetadata {
            rawMetadata = persistentStoreMetadata
        } else {
            do {
                rawMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    type: .sqlite,
                    at: storeURL
                )
            } catch {
                return .unknown
            }
        }

        guard let storeVersion = schemaVersion(from: rawMetadata) else {
            return .unknown
        }
        if storeVersion > latestSupportedSchemaVersion {
            return .requiresNewerReader(requiredSchemaVersion: storeVersion)
        }
        return .compatible(storeSchemaVersion: storeVersion)
    }

    public static func schemaVersion(from persistentStoreMetadata: [String: Any]) -> Int? {
        let value = persistentStoreMetadata[NSStoreModelVersionIdentifiersKey]
        let identifiers: [String]
        if let strings = value as? [String] {
            identifiers = strings
        } else if let set = value as? Set<String> {
            identifiers = Array(set)
        } else if let string = value as? String {
            identifiers = [string]
        } else {
            return nil
        }

        return identifiers.compactMap { identifier in
            let major = identifier.split(separator: ".", maxSplits: 1).first
            return major.flatMap { Int($0) }
        }.max()
    }
}
