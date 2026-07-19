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
    case capabilityStorageUncapturable(String)

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
        case .capabilityStorageUncapturable(let id):
            return "A capability (\(id)) already exists on this machine and its storage could not be safely backed up, so the import was stopped to avoid losing it."
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
    /// Connectors with no credentials but non-secret config keys whose values do
    /// not travel — unusable until the recipient re-enters the settings.
    var connectorsNeedingConfiguration: [String]
    var googleAccountsRequiringReauth: [String]
    var sshConnectionsRequiringLocalKeys: [String]
    /// Referenced pack IDs the recipient's catalog lacks; imported without them.
    var packsUnavailable: [String]
    /// Capability IDs the share referenced (built-in or remote-approved on the
    /// exporting machine) that could not be enabled here because they are not
    /// installed-and-approved on this machine. The workspace imports without
    /// them; the recipient must install/approve then enable after import.
    var capabilitiesUnavailable: [String]
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
/// Whether an installed capability is *effectively* approved for exposure —
/// the same digest-bound record check the runtime catalog policy uses, not the
/// on-disk governance (which `CapabilityLibrary.decodeInstalledPackage`
/// normalizes to `.draft` for every non-built-in, so a raw
/// `approvalStatus == .approved` check can never recognize a locally-approved
/// custom capability).
enum WorkspacePackageCapabilityApproval {
    static func isEffectivelyApproved(
        _ package: PluginPackage,
        records: [CapabilityApprovalRecord]
    ) -> Bool {
        // Built-ins carry compiled/curated governance on decode, so an approved
        // built-in already reads as `.approved` here.
        if package.governance.approvalStatus == .approved { return true }
        let versionRecords = records.filter {
            $0.packageID == package.id && $0.packageVersion == package.version
        }
        guard !versionRecords.isEmpty,
              let digest = try? CapabilityApprovalDigest.digest(for: package) else { return false }
        return versionRecords.last(where: { $0.sourceDigest == digest })?.status == .approved
    }
}

@MainActor
struct WorkspacePackageImportCoordinator {
    var fileManager: FileManager = .default
    var packageService = WorkspacePackageService()
    var appPackageService = WorkspaceAppPackageService()
    var capabilityLibrary = CapabilityLibrary()
    /// Digest-bound capability approval records (runtime source of truth for
    /// local approval); injectable so tests can model an approved custom
    /// capability without touching the real approvals directory.
    var approvalRecords: () -> [CapabilityApprovalRecord] = { CapabilityApprovalStore().records() }
    /// Fault-injection seam for tests (`FeedbackEvidenceBuilder`'s injectable
    /// closure pattern) — production always uses the real app import.
    var importAppBundle: (@MainActor (URL, Workspace, ModelContext) throws -> WorkspaceAppPackageImportResult)?

    /// A whole-package fingerprint: the digest of `checksums.json`, which itself
    /// content-hashes every portable file, so any change to any file changes it.
    /// The review flow captures this when it builds the plan and passes it back
    /// as `expectedPackageDigest` so the import can prove it is committing the
    /// bytes the user actually reviewed. `nonisolated` — pure filesystem read,
    /// and `stageAndValidate` below (running off the main actor) needs to call
    /// it without an actor hop.
    nonisolated static func packageFingerprint(at packageURL: URL) -> String? {
        try? PortablePackageSafeFileReader.digest(rootURL: packageURL, relativePath: "checksums.json")
    }

    private struct StagedPackage: Sendable {
        var stagingRoot: URL
        var stagedPackageURL: URL
        var manifest: WorkspacePackageManifest
        var document: WorkspaceShareDocument
        /// Embedded-app validation reports produced during the off-main staging
        /// pass, keyed by logical ID — reused at import so the nested bundles
        /// aren't enumerated and hashed a second time on the main actor.
        var appReports: [String: WorkspaceAppPackageValidationReport]
    }

    /// Stages a private, bounded copy of `packageURL` and re-validates it —
    /// pure filesystem/CPU work with no SwiftData involvement. `nonisolated`
    /// so the `Task.detached` in `importPackage` genuinely runs this off the
    /// main actor instead of hopping straight back for it.
    nonisolated private static func stageAndValidate(
        packageURL: URL,
        expectedPackageDigest: String?,
        fileManager: FileManager,
        packageService: WorkspacePackageService
    ) throws -> StagedPackage {
        // Copy the package into a private staging directory and consume ONLY
        // that copy. The source URL may sit in a shared or attacker-writable
        // location; validating it and then re-reading capability JSON and app
        // bundles from it leaves a window where the bytes are swapped between
        // check and use. Once copied here, nothing outside this process can
        // change what we validate and install.
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("astra-share-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: stagingRoot) } }

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

        succeeded = true
        return StagedPackage(
            stagingRoot: stagingRoot,
            stagedPackageURL: stagedPackageURL,
            manifest: manifest,
            document: document,
            appReports: report.appReports
        )
    }

    func importPackage(
        at packageURL: URL,
        intoDestinationFolder parentFolder: URL,
        modelContext: ModelContext,
        expectedPackageDigest: String? = nil
    ) async throws -> WorkspacePackageImportOutcome {
        // Stage and re-validate off the main actor: a package near the 500MB
        // review limit would otherwise freeze the UI for the whole bounded
        // copy, checksum validation, and nested app validation. Only the
        // SwiftData mutation phase below needs the main actor.
        let fileManager = self.fileManager
        let packageService = self.packageService
        let staged = try await Task.detached(priority: .userInitiated) {
            try Self.stageAndValidate(
                packageURL: packageURL,
                expectedPackageDigest: expectedPackageDigest,
                fileManager: fileManager,
                packageService: packageService
            )
        }.value
        defer { try? fileManager.removeItem(at: staged.stagingRoot) }
        let stagedPackageURL = staged.stagedPackageURL
        let manifest = staged.manifest
        let document = staged.document

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
        // Snapshot each capability's storage BEFORE installing, so rollback can
        // restore the prior bytes — including a malformed/unreadable package that
        // `installedPackages()` omits (so `claimedStorageNames` misses it) and the
        // install would otherwise overwrite with no way back. `restorePackageStorage`
        // removes the new install when the snapshot was empty (== the old
        // remove-package behavior) and restores the captured bytes when it wasn't.
        var capabilityStorageSnapshots: [CapabilityLibrary.PackageStorageSnapshot] = []
        var committed = false
        defer {
            if !committed {
                importContext.rollback()
                for snapshot in capabilityStorageSnapshots.reversed() {
                    capabilityLibrary.restorePackageStorage(snapshot)
                }
                try? fileManager.removeItem(at: workspaceRootURL)
            }
        }

        let importResult = try WorkspaceShareImporter.makeWorkspace(
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
            let snapshot = capabilityLibrary.makePackageStorageSnapshot(for: entry.packageID)
            // If the storage path is occupied but the snapshot copy failed
            // (existingStorageURL set, snapshotURL nil), `restorePackageStorage`
            // can't bring the prior bytes back — installing would overwrite them
            // irrecoverably on a later rollback. Refuse rather than risk data loss.
            if snapshot.existingStorageURL != nil, snapshot.snapshotURL == nil {
                throw WorkspacePackageImportError.capabilityStorageUncapturable(entry.packageID)
            }
            capabilityStorageSnapshots.append(snapshot)
            try capabilityLibrary.install(capability)
            capabilitiesInstalledAsDraft.append(entry.packageID)
            claimedStorageNames.insert(storageKey(entry.packageID))
        }

        var appsImported: [String] = []
        for entry in manifest.appEntries {
            let bundleURL = stagedPackageURL.appendingPathComponent(entry.relativeBundlePath, isDirectory: true)
            let result: WorkspaceAppPackageImportResult
            if let importAppBundle {
                result = try importAppBundle(bundleURL, workspace, importContext)
            } else if let stagedReport = staged.appReports[entry.logicalID] {
                // Reuse the report the off-main staging pass already produced,
                // rather than re-enumerating and re-hashing the bundle on the
                // main actor via the self-validating overload.
                result = try appPackageService.importPackage(
                    at: bundleURL,
                    validatedBy: stagedReport,
                    into: workspace,
                    modelContext: importContext,
                    persistence: .deferSave
                )
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
        let records = approvalRecords()
        workspace.enabledCapabilityIDs = workspace.enabledCapabilityIDs.filter { id in
            guard let installed = capabilityLibrary.installedPackage(id: id) else { return false }
            // Effective approval: a locally-approved CUSTOM capability's on-disk
            // governance is normalized to `.draft`, so its approval lives only in
            // a digest-bound approval record — the same source runtime exposure
            // uses. A raw `.approved` check would wrongly strip it here.
            return WorkspacePackageCapabilityApproval.isEffectivelyApproved(installed, records: records)
        }

        // Packs are referenced by ID only and are never embedded, so a share can
        // name a pack this machine does not have. Reconcile the enabled-pack set
        // down to packs that actually resolve in the recipient's catalog rather
        // than trusting arbitrary IDs: an unresolved enabled pack makes the
        // workspace hide pack-addressable shelves and applies an unresolved
        // policy. Missing packs are surfaced in the pre-import review.
        let availablePackIDs = Set(AstraPackCatalog().load().entries.map { $0.manifest.id })
        let packsUnavailable = workspace.enabledPackIDs.filter { !availablePackIDs.contains($0) }
        workspace.enabledPackIDs = workspace.enabledPackIDs.filter { availablePackIDs.contains($0) }

        // Every enable-intent capability that the reconciliation stripped and that
        // isn't otherwise disclosed (freshly installed as a draft, or skipped for
        // a storage conflict) is unavailable in the imported workspace — the
        // outcome must report it rather than let the review say everything is
        // ready. This covers a referenced non-embedded capability that isn't
        // approved here AND an embedded capability whose ID already existed
        // locally but lacks effective approval (recorded as already-installed,
        // yet stripped from the enabled set).
        let enabledAfterReconcile = Set(workspace.enabledCapabilityIDs)
        let otherwiseDisclosed = Set(capabilitiesInstalledAsDraft).union(capabilitiesSkippedForConflict)
        let capabilitiesUnavailable = document.capabilityIDs.filter {
            !enabledAfterReconcile.contains($0) && !otherwiseDisclosed.contains($0)
        }

        // Last chance to abort before any domain mutation is committed: if the
        // caller (the review sheet) was dismissed/cancelled during the import, do
        // not silently commit a workspace the user walked away from. Throwing here
        // runs the rollback defer (nothing is persisted).
        try Task.checkCancellation()
        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
            workspace: workspace,
            modelContext: importContext,
            auditFields: ["operation": "workspace_package_import"]
        )
        committed = true
        // The capability-storage snapshots existed only to enable rollback; the
        // import committed, so remove their temp directories now (the rollback
        // defer won't run on the committed path, which would otherwise leak them).
        for snapshot in capabilityStorageSnapshots {
            if let snapshotURL = snapshot.snapshotURL {
                try? fileManager.removeItem(at: snapshotURL.deletingLastPathComponent())
            }
        }
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
            connectorsNeedingConfiguration: document.connectors
                .filter { !$0.configKeys.isEmpty }
                .map(\.name),
            googleAccountsRequiringReauth: manifest.googleAccountsRequiringReauth,
            sshConnectionsRequiringLocalKeys: manifest.sshConnectionsRequiringLocalKeys,
            packsUnavailable: packsUnavailable,
            capabilitiesUnavailable: capabilitiesUnavailable,
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
        // `.` / `..` (or any all-dots name) are nonempty and pass name validation,
        // but as a directory component they resolve to the parent chain — import
        // would target the selected parent itself. Fall back for those.
        if sanitized.isEmpty || sanitized.allSatisfy({ $0 == "." }) {
            return "Imported Workspace"
        }
        return sanitized
    }

}

/// Routing shim for the shared "Import Workspace…" entry point: `.astra-share`
/// bundles go to the package review flow, everything else stays on the legacy
/// folder/JSON path untouched.
enum WorkspacePackageImportRouting {
    static func isPackageURL(_ url: URL) -> Bool {
        // Case-insensitive: a package renamed `Workspace.ASTRA-SHARE` must still
        // route to the readiness review, not be misclassified as a legacy folder
        // (which would import the bundle itself as a bare workspace).
        url.pathExtension.lowercased() == "astra-share"
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
