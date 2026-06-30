import Foundation
import SwiftData

/// Slice 3: published-manifest version history for Workspace Apps.
///
/// Each PUBLISH snapshots the manifest to `versions/v<n>.json` and records it in
/// `versions/index.json` (the source of truth). `WorkspaceApp` mirrors the latest
/// numbers in defaulted fields for cheap reads. Revert restores a prior published
/// manifest over the active one WITHOUT touching app storage/data.
///
/// The file-only methods are `nonisolated` + `FileManager`-injected (unit-testable
/// in a temp dir, matching `WorkspaceAppService`); only the methods that mutate the
/// `WorkspaceApp` @Model are `@MainActor`.
struct WorkspaceAppVersionService {
    var fileManager: FileManager = .default

    /// On-disk index of published snapshots. NOT a @Model — pure JSON, authoritative
    /// for the `versions/` directory.
    struct Index: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var number: Int
            var digest: String
            var publishedAt: Date
            var validated: Bool
        }
        var entries: [Entry] = []
        var publishedVersion: Int?
        var lastKnownGood: Int?
    }

    // MARK: - Snapshot on publish (file-only)

    /// Snapshot already-encoded manifest data as the next version, returning the new
    /// version number. Allocates from the index (max existing number + 1) so it needs
    /// no model read and never reuses or clobbers a prior snapshot.
    @discardableResult
    nonisolated func snapshotPublishedVersion(
        manifestData: Data,
        digest: String,
        validated: Bool,
        appID: String,
        workspacePath: String,
        now: Date = Date()
    ) throws -> Int {
        guard let versionsDir = WorkspaceFileLayout.appVersionsDirectoryURL(workspacePath: workspacePath, appID: appID) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve versions directory for app \(appID).")
        }
        try fileManager.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        var index = loadIndexOrEmpty(appID: appID, workspacePath: workspacePath)
        let next = (index.entries.map(\.number).max() ?? 0) + 1

        guard let versionFile = WorkspaceFileLayout.appVersionFileURL(
            workspacePath: workspacePath, appID: appID, versionNumber: next
        ) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve version file for app \(appID).")
        }
        try manifestData.write(to: versionFile, options: [.atomic])

        index.entries.append(Index.Entry(number: next, digest: digest, publishedAt: now, validated: validated))
        index.publishedVersion = next
        if validated { index.lastKnownGood = next }
        try writeIndex(index, appID: appID, workspacePath: workspacePath)
        return next
    }

    // MARK: - List (file-only)

    /// Snapshot history in version order (empty when the app has never published).
    nonisolated func listVersions(appID: String, workspacePath: String) -> [Index.Entry] {
        loadIndexOrEmpty(appID: appID, workspacePath: workspacePath)
            .entries.sorted { $0.number < $1.number }
    }

    nonisolated func loadIndexOrEmpty(appID: String, workspacePath: String) -> Index {
        (try? loadIndex(appID: appID, workspacePath: workspacePath)) ?? Index()
    }

    // MARK: - Mark last known good (file-only)

    /// Promote a version to last-known-good and mark its entry validated. Returns the
    /// entry's digest.
    @discardableResult
    nonisolated func markLastKnownGood(versionNumber: Int, appID: String, workspacePath: String) throws -> String {
        var index = try loadIndex(appID: appID, workspacePath: workspacePath)
        guard let position = index.entries.firstIndex(where: { $0.number == versionNumber }) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Version \(versionNumber) not found for app \(appID).")
        }
        index.entries[position].validated = true
        index.lastKnownGood = versionNumber
        try writeIndex(index, appID: appID, workspacePath: workspacePath)
        return index.entries[position].digest
    }

    // MARK: - Record publish (@MainActor: file snapshot + model mirror)

    /// The publish path's single entry point: snapshot the just-published manifest and
    /// mirror the version numbers/digests onto the @Model. Call AFTER `createApp`'s save
    /// has committed, so a stranded snapshot can never reference an unsaved app.
    @MainActor
    @discardableResult
    func recordPublish(
        app: WorkspaceApp,
        manifestData: Data,
        validated: Bool,
        workspacePath: String,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws -> Int {
        let digest = WorkspaceAppService.digest(for: manifestData)
        let number = try snapshotPublishedVersion(
            manifestData: manifestData, digest: digest, validated: validated,
            appID: app.logicalID, workspacePath: workspacePath, now: now
        )
        app.latestVersionNumber = number
        app.publishedManifestDigest = digest
        if validated { app.lastKnownGoodManifestDigest = digest }
        app.updatedAt = now
        try modelContext.save()
        return number
    }

    // MARK: - Revert (@MainActor: restore a prior published manifest)

    /// Restore a prior published manifest over the active one. Storage-preserving:
    /// touches only the manifest file + the @Model's digest/lifecycle, never `data/`,
    /// bindings, automations, or runs. Does NOT mint a new snapshot — it moves the
    /// published pointer back; history and `latestVersionNumber` are unchanged.
    @MainActor
    @discardableResult
    func revertToPreviousPublished(
        app: WorkspaceApp,
        in workspace: Workspace,
        modelContext: ModelContext,
        targetVersion: Int? = nil,
        now: Date = Date()
    ) throws -> Int {
        let workspacePath = workspace.primaryPath
        guard !workspacePath.isEmpty else { throw WorkspaceAppServiceError.emptyWorkspacePath }
        var index = try loadIndex(appID: app.logicalID, workspacePath: workspacePath)

        let target = try resolveRevertTarget(index: index, explicit: targetVersion)
        guard let entry = index.entries.first(where: { $0.number == target }) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Version \(target) not found for app \(app.logicalID).")
        }

        guard let versionFile = WorkspaceFileLayout.appVersionFileURL(
            workspacePath: workspacePath, appID: app.logicalID, versionNumber: target
        ) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve version \(target) for app \(app.logicalID).")
        }
        let data: Data
        do {
            data = try Data(contentsOf: versionFile)
        } catch {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not read version \(target): \(error.localizedDescription)")
        }

        // Defensive integrity: the snapshot is byte-identical to its publish, so the
        // recomputed digest must match the index. Refuse rather than half-apply.
        let restoredDigest = WorkspaceAppService.digest(for: data)
        guard restoredDigest == entry.digest else {
            throw WorkspaceAppServiceError.fileOperationFailed("Version \(target) is corrupt (digest mismatch).")
        }

        guard let manifestURL = WorkspaceFileLayout.appManifestFileURL(workspacePath: workspacePath, appID: app.logicalID) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve manifest path for app \(app.logicalID).")
        }
        try data.write(to: manifestURL, options: [.atomic])

        // Persist the moved pointer to the source of truth BEFORE mutating the @Model, so a
        // failed index write never leaves the model ahead of disk.
        index.publishedVersion = target
        try writeIndex(index, appID: app.logicalID, workspacePath: workspacePath)

        // Revert moves the `published` pointer back; it does NOT mint a new snapshot and does
        // NOT touch last-known-good — a newer validated version still exists on disk, so the
        // model's lastKnownGoodManifestDigest must keep mirroring index.lastKnownGood.
        app.manifestDigest = restoredDigest
        app.publishedManifestDigest = restoredDigest
        app.lifecycleStatus = .published
        app.updatedAt = now
        try modelContext.save()
        return target
    }

    /// Prefer the most recent VALIDATED version strictly before the current published
    /// pointer; fall back to the most recent published-before-current regardless of
    /// validation. (In practice every published manifest validated, since publish is
    /// gated on a valid manifest.)
    private nonisolated func resolveRevertTarget(index: Index, explicit: Int?) throws -> Int {
        if let explicit {
            guard index.entries.contains(where: { $0.number == explicit }) else {
                throw WorkspaceAppServiceError.fileOperationFailed("Requested version \(explicit) does not exist.")
            }
            return explicit
        }
        let current = index.publishedVersion ?? (index.entries.map(\.number).max() ?? 0)
        let priors = index.entries.filter { $0.number < current }
        guard !priors.isEmpty else {
            throw WorkspaceAppServiceError.fileOperationFailed("No prior published version to revert to.")
        }
        if let validated = priors.filter(\.validated).map(\.number).max() { return validated }
        // `priors` is non-empty, so a max always exists.
        return priors.map(\.number).max() ?? current
    }

    // MARK: - Index I/O (file-only)

    private nonisolated func loadIndex(appID: String, workspacePath: String) throws -> Index {
        guard let url = WorkspaceFileLayout.appVersionsIndexFileURL(workspacePath: workspacePath, appID: appID) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve versions index for app \(appID).")
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Index.self, from: data)
    }

    private nonisolated func writeIndex(_ index: Index, appID: String, workspacePath: String) throws {
        guard let url = WorkspaceFileLayout.appVersionsIndexFileURL(workspacePath: workspacePath, appID: appID) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve versions index for app \(appID).")
        }
        let data = try Self.encoder.encode(index)
        try data.write(to: url, options: [.atomic])
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
