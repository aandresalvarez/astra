import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum WorkspacePackageImportError: LocalizedError {
    case validationFailed([PortablePackageValidationIssue])
    case destinationAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "The package did not validate.\n\(messages)"
        case .destinationAlreadyExists(let path):
            return "A folder already exists at \(path). Choose a different destination."
        }
    }
}

/// Post-import readiness checklist: what landed, what stayed disabled, and
/// what the recipient still has to set up locally.
struct WorkspacePackageImportOutcome {
    var workspace: Workspace
    var workspaceRootURL: URL
    var appsImported: [String]
    var capabilitiesInstalledAsDraft: [String]
    var capabilitiesAlreadyInstalled: [String]
    var skillCount: Int
    var connectorCount: Int
    var localToolCount: Int
    var quarantinedScheduleCount: Int
    var connectorsNeedingCredentials: [String]
    var googleAccountsRequiringReauth: [String]
    var sshConnectionsRequiringLocalKeys: [String]
    var droppedMachinePaths: [String]
}

/// Transactional import of a `.astra-share` package.
///
/// Deliberately a NEW type rather than an extension of the narrower legacy
/// `WorkspaceImportOrchestrator` (which imports raw dropped folders/JSON
/// mirrors with no plan, staging, or rollback). Mutations span two domains no
/// single transaction covers — SwiftData rows and the filesystem — so the
/// rollback model is: the destination folder is always created fresh by this
/// import (deleting it undoes every file this import wrote, and can never
/// clobber pre-existing user data), SwiftData stays unsaved until the single
/// commit point at the end (`modelContext.rollback()` undoes all of it —
/// every app import runs with `.deferSave` for exactly this reason), and
/// capability-library installs outside the destination are compensated
/// individually, mirroring `CapabilityInstaller`'s rollback-plus-restore
/// pattern (`CapabilityInstaller.swift:284-298`).
@MainActor
struct WorkspacePackageImportCoordinator {
    var fileManager: FileManager = .default
    var packageService = WorkspacePackageService()
    var appPackageService = WorkspaceAppPackageService()
    var capabilityLibrary = CapabilityLibrary()
    /// Fault-injection seam for tests (`FeedbackEvidenceBuilder`'s injectable
    /// closure pattern) — production always uses the real app import.
    var importAppBundle: (@MainActor (URL, Workspace, ModelContext) throws -> WorkspaceAppPackageImportResult)?

    func importPackage(
        at packageURL: URL,
        intoDestinationFolder parentFolder: URL,
        modelContext: ModelContext
    ) throws -> WorkspacePackageImportOutcome {
        // Re-validate at import time: the package may have changed since the
        // review plan was built (TOCTOU), and callers are not trusted to have
        // validated at all.
        let report = packageService.validatePackage(at: packageURL)
        guard report.canInstall, let manifest = report.manifest, var config = report.workspaceConfig else {
            throw WorkspacePackageImportError.validationFailed(report.blockers)
        }

        let workspaceRootURL = parentFolder.appendingPathComponent(
            Self.directoryName(for: manifest.workspaceName),
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: workspaceRootURL.path) else {
            throw WorkspacePackageImportError.destinationAlreadyExists(workspaceRootURL.path)
        }

        // The explicit destination is the workspace root — never the folder
        // the package happens to sit in (the legacy JSON path's Downloads
        // anchoring bug this format exists to avoid). Machine-local paths
        // from the exporting machine are dropped, surfaced in the outcome.
        var droppedPaths = config.additionalPaths
        if let activeWorkingPath = config.activeWorkingPath, !activeWorkingPath.isEmpty {
            droppedPaths.append(activeWorkingPath)
        }
        config.primaryPath = workspaceRootURL.path
        config.additionalPaths = []
        config.activeWorkingPath = nil
        // A portable share behaves like "duplicate", never "replace": two
        // recipients of the same package must not collide on workspace
        // identity, so the source ID is display metadata only.
        config.id = nil

        // Embedded custom capabilities land as local drafts pending review (see
        // the capability loop below). But `config.enabledCapabilityIDs` carries
        // the sender's enabled set verbatim, and the runtime resource matcher
        // exposes enabled capabilities to task runs regardless of governance —
        // so a freshly-imported draft would run immediately, contradicting the
        // "pending approval" the review UI shows. Strip any embedded capability
        // that is not already installed-and-approved on this machine from the
        // imported workspace's enabled set; the recipient re-enables it after
        // approving. Built-in / already-approved capabilities keep their state.
        let embeddedIDsNeedingApproval = Set(manifest.capabilityEntries.map(\.packageID).filter { id in
            guard let installed = capabilityLibrary.installedPackage(id: id) else { return true }
            return installed.governance.approvalStatus != .approved
        })
        if !embeddedIDsNeedingApproval.isEmpty {
            config.enabledCapabilityIDs = (config.enabledCapabilityIDs ?? [])
                .filter { !embeddedIDsNeedingApproval.contains($0) }
        }

        try fileManager.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        var installedCapabilityIDs: [String] = []
        var committed = false
        defer {
            if !committed {
                modelContext.rollback()
                for id in installedCapabilityIDs {
                    try? capabilityLibrary.removePackage(id: id)
                }
                try? fileManager.removeItem(at: workspaceRootURL)
            }
        }

        let configResult = WorkspaceConfigManager.importWorkspaceResult(
            from: config,
            modelContext: modelContext,
            scheduleTrustPolicy: .quarantineEnabledSchedules
        )
        let workspace = configResult.workspace

        // Install embedded capabilities BEFORE importing the apps. App
        // dependency bindings are resolved by `WorkspaceAppService.createApp`
        // against the currently-installed capability library; if an app that
        // declares a capability-provided contract is created first, its binding
        // is persisted as unmapped and the later install never recreates it, so
        // the app stays stuck in a missing-dependency state even after the
        // recipient approves the capability.
        var capabilitiesInstalledAsDraft: [String] = []
        var capabilitiesAlreadyInstalled: [String] = []
        for entry in manifest.capabilityEntries {
            if capabilityLibrary.installedPackage(id: entry.packageID) != nil {
                capabilitiesAlreadyInstalled.append(entry.packageID)
                continue
            }
            let data = try PortablePackageSafeFileReader.readData(
                rootURL: packageURL,
                relativePath: entry.relativePath
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var capability = try decoder.decode(PluginPackage.self, from: data)
            // Validation already rejected non-draft governance; clamp again
            // anyway so a future validation regression can't turn this write
            // into a self-approved install.
            CapabilityGovernanceNormalizer.clampToLocalDraft(&capability)
            try capabilityLibrary.install(capability)
            installedCapabilityIDs.append(entry.packageID)
            capabilitiesInstalledAsDraft.append(entry.packageID)
        }

        var appsImported: [String] = []
        for entry in manifest.appEntries {
            let bundleURL = packageURL.appendingPathComponent(entry.relativeBundlePath, isDirectory: true)
            let result: WorkspaceAppPackageImportResult
            if let importAppBundle {
                result = try importAppBundle(bundleURL, workspace, modelContext)
            } else {
                result = try appPackageService.importPackage(
                    at: bundleURL,
                    into: workspace,
                    modelContext: modelContext,
                    persistence: .deferSave
                )
            }
            appsImported.append(result.app.name)
        }

        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
            workspace: workspace,
            modelContext: modelContext,
            auditFields: ["operation": "workspace_package_import"]
        )
        committed = true
        // Post-commit: write the new workspace's own recovery mirror into the
        // destination, matching the legacy import orchestrator's behavior.
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.workspaceImported, category: "App", fields: [
            "source": "portable_package",
            "workspace_id": workspace.id.uuidString,
            "app_count": String(appsImported.count),
            "capability_count": String(capabilitiesInstalledAsDraft.count)
        ])

        return WorkspacePackageImportOutcome(
            workspace: workspace,
            workspaceRootURL: workspaceRootURL,
            appsImported: appsImported,
            capabilitiesInstalledAsDraft: capabilitiesInstalledAsDraft,
            capabilitiesAlreadyInstalled: capabilitiesAlreadyInstalled,
            skillCount: configResult.skillCount,
            connectorCount: configResult.connectorCount,
            localToolCount: configResult.localToolCount,
            quarantinedScheduleCount: configResult.quarantinedScheduleCount,
            connectorsNeedingCredentials: (config.connectors ?? [])
                .filter { !$0.credentialKeys.isEmpty }
                .map(\.name),
            googleAccountsRequiringReauth: manifest.googleAccountsRequiringReauth,
            sshConnectionsRequiringLocalKeys: manifest.sshConnectionsRequiringLocalKeys,
            droppedMachinePaths: droppedPaths
        )
    }

    static func directoryName(for workspaceName: String) -> String {
        let sanitized = workspaceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Imported Workspace" : sanitized
    }
}

/// Routing shim for the shared "Import Workspace…" entry point: `.astra-share`
/// bundles go to the package review flow, everything else stays on the legacy
/// folder/JSON path untouched.
enum WorkspacePackageImportRouting {
    static func isPackageURL(_ url: URL) -> Bool {
        url.pathExtension == "astra-share"
    }

    static func partition(_ urls: [URL]) -> (packageURLs: [URL], legacyURLs: [URL]) {
        var packages: [URL] = []
        var legacy: [URL] = []
        for url in urls {
            if isPackageURL(url) {
                packages.append(url)
            } else {
                legacy.append(url)
            }
        }
        return (packages, legacy)
    }
}
