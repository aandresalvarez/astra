import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum WorkspacePackageImportError: LocalizedError {
    case validationFailed([PortablePackageValidationIssue])
    case destinationAlreadyExists(String)
    case packageChangedSinceReview
    case unsafePackageSymlink(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "The package did not validate.\n\(messages)"
        case .destinationAlreadyExists(let path):
            return "A folder already exists at \(path). Choose a different destination."
        case .packageChangedSinceReview:
            return "This package changed after you reviewed it. Re-open it to review the new contents before importing."
        case .unsafePackageSymlink(let component):
            return "The package contains a symbolic link (\(component)) and cannot be safely imported."
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
    var capabilitiesSkippedForConflict: [String]
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

    /// A whole-package fingerprint: the digest of `checksums.json`, which itself
    /// content-hashes every portable file, so any change to any file changes it.
    /// The review flow captures this when it builds the plan and passes it back
    /// as `expectedPackageDigest` so the import can prove it is committing the
    /// bytes the user actually reviewed.
    static func packageFingerprint(at packageURL: URL) -> String? {
        try? PortablePackageSafeFileReader.digest(rootURL: packageURL, relativePath: "checksums.json")
    }

    func importPackage(
        at packageURL: URL,
        intoDestinationFolder parentFolder: URL,
        modelContext: ModelContext,
        expectedPackageDigest: String? = nil
    ) throws -> WorkspacePackageImportOutcome {
        // Copy the package into a private staging directory and consume ONLY
        // that copy. The source URL may sit in a shared or attacker-writable
        // location; validating it and then re-reading capability JSON and app
        // bundles from it leaves a window where the bytes are swapped between
        // check and use. Once copied here, nothing outside this process can
        // change what we validate and install.
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("astra-share-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        let stagedPackageURL = stagingRoot.appendingPathComponent("package.astra-share", isDirectory: true)
        try fileManager.copyItem(at: packageURL, to: stagedPackageURL)

        // `copyItem` preserves symlinks rather than dereferencing them, so if the
        // selected package root — or any entry inside it — is a symlink, the
        // "staged copy" is still an alias to a location the source machine (or an
        // attacker) can rewrite after the digest check. That defeats the whole
        // point of staging. Refuse any symlink in the staged tree so what we
        // validate and install is a genuinely private, self-contained snapshot.
        if let symlink = PortablePackageSafeFileReader.firstSymlink(in: stagedPackageURL) {
            throw WorkspacePackageImportError.unsafePackageSymlink(symlink)
        }

        // Bind the commit to the reviewed bytes: a package swapped for a
        // different (still-valid) one between review and confirmation would
        // otherwise import without its inventory ever being shown. Compare the
        // staged copy's fingerprint against the one the caller reviewed.
        if let expectedPackageDigest,
           Self.packageFingerprint(at: stagedPackageURL) != expectedPackageDigest {
            throw WorkspacePackageImportError.packageChangedSinceReview
        }

        // Re-validate the STAGED copy (callers are not trusted to have validated,
        // and this is the exact byte set that will be installed).
        let report = packageService.validatePackage(at: stagedPackageURL)
        guard report.canInstall, let manifest = report.manifest, var config = report.workspaceConfig else {
            throw WorkspacePackageImportError.validationFailed(report.blockers)
        }

        // Do every SwiftData mutation in a dedicated context on the same store,
        // never the caller's shared UI context. Otherwise a rollback on failure
        // would discard the user's unrelated pending edits in the open workspace,
        // and the final save would persist them — this operation must own exactly
        // its own rows. The committed workspace is re-fetched into the caller's
        // context at the end so the UI receives a usable object.
        let importContext = ModelContext(modelContext.container)

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

        // An untrusted share must not mutate the recipient's GLOBAL catalog.
        // Skill/connector/tool configs can carry `isGlobal: true`, which the
        // generic importer honors by creating a workspace-less global resource
        // and adding it to the enabled-global set — so importing one shared
        // workspace would install globally-reusable definitions across the
        // recipient's whole install. Force every imported resource to be scoped
        // to the new workspace and drop the enable-global references, so a share
        // only ever populates the workspace it creates.
        config.skills = config.skills.map { var resource = $0; resource.isGlobal = false; return resource }
        config.connectors = config.connectors?.map { var resource = $0; resource.isGlobal = false; return resource }
        config.localTools = config.localTools?.map { var resource = $0; resource.isGlobal = false; return resource }
        config.enabledGlobalSkillIDs = []
        config.enabledGlobalConnectorIDs = []
        config.enabledGlobalToolIDs = []

        // `config.enabledCapabilityIDs` carries the sender's enabled set
        // verbatim, and the runtime resource matcher exposes enabled capabilities
        // to task runs regardless of governance. The set is reconciled AFTER the
        // apps are imported (see below), not here: `WorkspaceAppService.createApp`
        // derives an app's dependency bindings from the workspace's CURRENTLY
        // enabled capabilities, so any capability an app depends on must still be
        // enabled when the apps are created or the binding persists unmapped and
        // never recovers.

        try fileManager.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        var installedCapabilityIDs: [String] = []
        var committed = false
        defer {
            if !committed {
                importContext.rollback()
                for id in installedCapabilityIDs {
                    try? capabilityLibrary.removePackage(id: id)
                }
                try? fileManager.removeItem(at: workspaceRootURL)
            }
        }

        let configResult = WorkspaceConfigManager.importWorkspaceResult(
            from: config,
            modelContext: importContext,
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
        var capabilitiesSkippedForConflict: [String] = []
        // The library stores each package at `<safeFileName(id)>.json`, and
        // `safeFileName` is lossy — distinct IDs like `a.b` and `a-b` both map to
        // `a-b.json`. An exact-ID lookup misses that, so installing an embedded
        // `a.b` would overwrite a recipient's existing `a-b`, and rollback (which
        // only removes what it installed) could not restore the clobbered file.
        // Track claimed storage names — seeded from what's already installed and
        // extended as this loop installs — and skip any embedded capability whose
        // storage name is already taken by a DIFFERENT package rather than
        // destroy the recipient's data.
        var claimedStorageNames = Set(capabilityLibrary.installedPackages().map { CapabilityLibrary.safeFileName(for: $0.id) })
        for entry in manifest.capabilityEntries {
            if capabilityLibrary.installedPackage(id: entry.packageID) != nil {
                capabilitiesAlreadyInstalled.append(entry.packageID)
                continue
            }
            if claimedStorageNames.contains(CapabilityLibrary.safeFileName(for: entry.packageID)) {
                capabilitiesSkippedForConflict.append(entry.packageID)
                continue
            }
            let data = try PortablePackageSafeFileReader.readData(
                rootURL: stagedPackageURL,
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
            claimedStorageNames.insert(CapabilityLibrary.safeFileName(for: entry.packageID))
        }

        var appsImported: [String] = []
        for entry in manifest.appEntries {
            let bundleURL = stagedPackageURL.appendingPathComponent(entry.relativeBundlePath, isDirectory: true)
            let result: WorkspaceAppPackageImportResult
            if let importAppBundle {
                result = try importAppBundle(bundleURL, workspace, importContext)
            } else {
                result = try appPackageService.importPackage(
                    at: bundleURL,
                    into: workspace,
                    modelContext: importContext,
                    persistence: .deferSave
                )
            }
            appsImported.append(result.app.name)
        }

        // Now that every app's dependency bindings have been resolved against
        // the fully-enabled capability set (mapped, not missing), reconcile the
        // enabled set down to only what is safe to expose immediately: a
        // capability that is built-in or already approved ON THIS MACHINE. Every
        // other referenced ID is removed — an embedded draft just installed, a
        // recipient-local capability with the same ID that was never approved,
        // or an ID that resolves to nothing here. This closes two holes: an
        // untrusted share cannot run its own unreviewed draft, and it cannot
        // silently activate one of the recipient's own unapproved local tools by
        // merely naming its ID in the enabled set. The mapped binding rows
        // persist independently, so the recipient re-enables after review without
        // a manual re-bind. Nothing runs between here and the commit below, so
        // there is no window where a pending capability is live.
        workspace.enabledCapabilityIDs = workspace.enabledCapabilityIDs.filter { id in
            capabilityLibrary.installedPackage(id: id)?.governance.approvalStatus == .approved
        }

        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
            workspace: workspace,
            modelContext: importContext,
            auditFields: ["operation": "workspace_package_import"]
        )
        committed = true
        // Post-commit: write the new workspace's own recovery mirror into the
        // destination, matching the legacy import orchestrator's behavior.
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: importContext)
        AppLogger.audit(.workspaceImported, category: "App", fields: [
            "source": "portable_package",
            "workspace_id": workspace.id.uuidString,
            "app_count": String(appsImported.count),
            "capability_count": String(capabilitiesInstalledAsDraft.count)
        ])

        // The workspace above belongs to the dedicated import context. Re-fetch
        // it into the caller's context so the UI (selection, @Query) receives an
        // object it owns; fall back to the import-context object if the caller's
        // context can't see the just-committed row for any reason.
        let importedID = workspace.id
        let outcomeWorkspace = (try? modelContext.fetch(
            FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == importedID })
        ).first) ?? workspace

        return WorkspacePackageImportOutcome(
            workspace: outcomeWorkspace,
            workspaceRootURL: workspaceRootURL,
            appsImported: appsImported,
            capabilitiesInstalledAsDraft: capabilitiesInstalledAsDraft,
            capabilitiesAlreadyInstalled: capabilitiesAlreadyInstalled,
            capabilitiesSkippedForConflict: capabilitiesSkippedForConflict,
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
