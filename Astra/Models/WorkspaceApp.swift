import Foundation
import SwiftData

public enum WorkspaceAppLifecycleStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case draft
    case published
    case disabled
    case blocked
}

public enum WorkspaceAppPermissionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly
    case draftOnly
    case approvalRequired
    case preApproved
}

public enum WorkspaceAppDependencyStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case unresolved
    case ready
    case missingRequired
    case blocked
}

@Model
public final class WorkspaceApp: Identifiable {
    public var id: UUID
    public var workspaceID: UUID
    public var logicalID: String
    public var name: String
    public var icon: String
    public var appDescription: String
    public var lifecycleStatusRaw: String
    public var permissionModeRaw: String
    public var dependencyStatusRaw: String
    public var manifestRelativePath: String
    public var appDirectoryRelativePath: String
    public var manifestDigest: String
    // Slice 3 versioning. Defaulted so they are absorbed into ASTRASchemaV8's fresh
    // table (same pattern as WorkspaceAppRun.pendingStepIndex / awaitedTaskIDsJSON);
    // NO new @Model, NO new schema version. The on-disk versions/index.json is the
    // source of truth; these mirror it for cheap reads without a directory scan.
    public var publishedManifestDigest: String = ""      // digest of the last manifest that PUBLISHED; "" = never published
    public var lastKnownGoodManifestDigest: String = ""  // digest of the last manifest that published AND validated; "" = none
    public var latestVersionNumber: Int = 0              // highest snapshot number written to versions/; 0 = none
    public var sourcePackageID: String?
    public var sourcePackageVersion: String?
    public var sourcePackageDigest: String?
    public var lastOpenedAt: Date?
    public var lastRefreshedAt: Date?
    public var lastRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        logicalID: String,
        name: String,
        icon: String = "square.grid.2x2",
        appDescription: String = "",
        lifecycleStatus: WorkspaceAppLifecycleStatus = .draft,
        permissionMode: WorkspaceAppPermissionMode = .readOnly,
        dependencyStatus: WorkspaceAppDependencyStatus = .unresolved,
        manifestRelativePath: String,
        appDirectoryRelativePath: String,
        manifestDigest: String,
        publishedManifestDigest: String = "",
        lastKnownGoodManifestDigest: String = "",
        latestVersionNumber: Int = 0,
        sourcePackageID: String? = nil,
        sourcePackageVersion: String? = nil,
        sourcePackageDigest: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.logicalID = logicalID
        self.name = name
        self.icon = icon
        self.appDescription = appDescription
        self.lifecycleStatusRaw = lifecycleStatus.rawValue
        self.permissionModeRaw = permissionMode.rawValue
        self.dependencyStatusRaw = dependencyStatus.rawValue
        self.manifestRelativePath = manifestRelativePath
        self.appDirectoryRelativePath = appDirectoryRelativePath
        self.manifestDigest = manifestDigest
        self.publishedManifestDigest = publishedManifestDigest
        self.lastKnownGoodManifestDigest = lastKnownGoodManifestDigest
        self.latestVersionNumber = latestVersionNumber
        self.sourcePackageID = sourcePackageID
        self.sourcePackageVersion = sourcePackageVersion
        self.sourcePackageDigest = sourcePackageDigest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var lifecycleStatus: WorkspaceAppLifecycleStatus {
        get { WorkspaceAppLifecycleStatus(rawValue: lifecycleStatusRaw) ?? .draft }
        set { lifecycleStatusRaw = newValue.rawValue }
    }

    public var permissionMode: WorkspaceAppPermissionMode {
        get { WorkspaceAppPermissionMode(rawValue: permissionModeRaw) ?? .readOnly }
        set { permissionModeRaw = newValue.rawValue }
    }

    public var dependencyStatus: WorkspaceAppDependencyStatus {
        get { WorkspaceAppDependencyStatus(rawValue: dependencyStatusRaw) ?? .unresolved }
        set { dependencyStatusRaw = newValue.rawValue }
    }
}
