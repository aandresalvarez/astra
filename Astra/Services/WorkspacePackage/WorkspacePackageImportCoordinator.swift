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
    case packageTooLarge

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
        case .packageTooLarge:
            return "The package is too large to import safely."
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
        // Build the private snapshot with symlink rejection and file-count /
        // byte budgets enforced during the walk — not a bare recursive copyItem,
        // which a package swapped for a huge or link-laden tree could exploit to
        // burn temp disk and block before the fingerprint check runs.
        do {
            try PortablePackageSafeFileReader.stageBoundedCopy(
                from: packageURL,
                to: stagedPackageURL,
                fileManager: fileManager
            )
        } catch let PortablePackageStagingError.containsSymlink(component) {
            throw WorkspacePackageImportError.unsafePackageSymlink(component)
        } catch PortablePackageStagingError.tooManyFiles, PortablePackageStagingError.tooLarge {
            throw WorkspacePackageImportError.packageTooLarge
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
        guard report.canInstall, let manifest = report.manifest, let document = report.shareDocument else {
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
        // Claim the workspace directory EXCLUSIVELY. A `fileExists` check followed
        // by `createDirectory(withIntermediateDirectories: true)` is a TOCTOU: the
        // create silently accepts a directory another process made in between, and
        // this import would then believe it owns a folder whose files its own
        // rollback (`removeItem` below) could delete. Creating the parent chain
        // first, then the leaf with `withIntermediateDirectories: false`, makes the
        // leaf create fail if it already exists — an atomic claim.
        try fileManager.createDirectory(at: parentFolder, withIntermediateDirectories: true)
        do {
            try fileManager.createDirectory(at: workspaceRootURL, withIntermediateDirectories: false)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            throw WorkspacePackageImportError.destinationAlreadyExists(workspaceRootURL.path)
        }

        // The `WorkspaceShareDocument` carries NO machine-local paths, `isGlobal`
        // flags, enabled-global refs, Google account rows, or stable resource
        // UUIDs — the format structurally cannot express them — so none of the
        // old per-field neutralization is needed. `WorkspaceShareImporter` builds
        // a fresh, fully workspace-scoped graph (new UUIDs, never the global-reuse
        // or built-in-name paths), and the destination folder is always the
        // workspace root (never wherever the package sat).
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

        let importResult = WorkspaceShareImporter.makeWorkspace(
            from: document,
            primaryPath: workspaceRootURL.path,
            modelContext: importContext
        )
        let workspace = importResult.workspace
        // Enabled-capability intent stays populated through app import so
        // dependency bindings map against the full set; it is reconciled to
        // approved-only after the apps are created (see below).

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
        // destroy the recipient's data. Compared case-INSENSITIVELY: the default
        // macOS filesystem is case-insensitive, so `Foo`/`foo` share one path
        // (and `CapabilityPackageValidator.validateIdentity` lowercases for the
        // same reason).
        func storageKey(_ id: String) -> String { CapabilityLibrary.safeFileName(for: id).lowercased() }
        var claimedStorageNames = Set(capabilityLibrary.installedPackages().map { storageKey($0.id) })
        for entry in manifest.capabilityEntries {
            if capabilityLibrary.installedPackage(id: entry.packageID) != nil {
                capabilitiesAlreadyInstalled.append(entry.packageID)
                continue
            }
            if claimedStorageNames.contains(storageKey(entry.packageID)) {
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
            claimedStorageNames.insert(storageKey(entry.packageID))
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
            skillCount: importResult.skillCount,
            connectorCount: importResult.connectorCount,
            localToolCount: importResult.localToolCount,
            quarantinedScheduleCount: importResult.scheduleCount,
            connectorsNeedingCredentials: document.connectors
                .filter { !$0.credentialKeys.isEmpty }
                .map(\.name),
            googleAccountsRequiringReauth: manifest.googleAccountsRequiringReauth,
            sshConnectionsRequiringLocalKeys: manifest.sshConnectionsRequiringLocalKeys,
            // Machine-local paths never travel in the share format, so there is
            // nothing dropped on import to report back.
            droppedMachinePaths: []
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
