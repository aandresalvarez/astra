import Foundation
import SwiftData

enum WorkspaceAppLifecycleStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case draft
    case published
    case disabled
    case blocked
}

enum WorkspaceAppPermissionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly
    case draftOnly
    case approvalRequired
    case preApproved
}

enum WorkspaceAppDependencyStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case unresolved
    case ready
    case missingRequired
    case blocked
}

@Model
final class WorkspaceApp: Identifiable {
    var id: UUID
    var workspaceID: UUID
    var logicalID: String
    var name: String
    var icon: String
    var appDescription: String
    var lifecycleStatusRaw: String
    var permissionModeRaw: String
    var dependencyStatusRaw: String
    var manifestRelativePath: String
    var appDirectoryRelativePath: String
    var manifestDigest: String
    // Slice 3 versioning. Defaulted so they are absorbed into ASTRASchemaV8's fresh
    // table (same pattern as WorkspaceAppRun.pendingStepIndex / awaitedTaskIDsJSON);
    // NO new @Model, NO new schema version. The on-disk versions/index.json is the
    // source of truth; these mirror it for cheap reads without a directory scan.
    var publishedManifestDigest: String = ""      // digest of the last manifest that PUBLISHED; "" = never published
    var lastKnownGoodManifestDigest: String = ""  // digest of the last manifest that published AND validated; "" = none
    var latestVersionNumber: Int = 0              // highest snapshot number written to versions/; 0 = none
    var sourcePackageID: String?
    var sourcePackageVersion: String?
    var sourcePackageDigest: String?
    var lastOpenedAt: Date?
    var lastRefreshedAt: Date?
    var lastRunAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
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

    var lifecycleStatus: WorkspaceAppLifecycleStatus {
        get { WorkspaceAppLifecycleStatus(rawValue: lifecycleStatusRaw) ?? .draft }
        set { lifecycleStatusRaw = newValue.rawValue }
    }

    var permissionMode: WorkspaceAppPermissionMode {
        get { WorkspaceAppPermissionMode(rawValue: permissionModeRaw) ?? .readOnly }
        set { permissionModeRaw = newValue.rawValue }
    }

    var dependencyStatus: WorkspaceAppDependencyStatus {
        get { WorkspaceAppDependencyStatus(rawValue: dependencyStatusRaw) ?? .unresolved }
        set { dependencyStatusRaw = newValue.rawValue }
    }
}
