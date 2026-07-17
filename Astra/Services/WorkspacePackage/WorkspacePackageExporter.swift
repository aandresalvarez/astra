import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum WorkspacePackageExportError: LocalizedError, Equatable {
    case workspaceConfigUnavailable
    case destinationAlreadyExists(String)
    case selfVerificationFailed([PortablePackageValidationIssue])

    var errorDescription: String? {
        switch self {
        case .workspaceConfigUnavailable:
            return "Could not export this workspace's configuration."
        case .destinationAlreadyExists(let path):
            return "A package already exists at \(path)."
        case .selfVerificationFailed(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Exported package did not validate.\n\(messages)"
        }
    }
}

struct WorkspacePackageExportResult: Equatable {
    var packageURL: URL
    var manifest: WorkspacePackageManifest
}

/// Builds a portable `.astra-share` package for a workspace's "Configuration
/// only" profile: settings, instructions, capabilities, and every workspace
/// app at `.templateOnly` — no task/run history, no app data.
///
/// Stages everything in a hidden directory beside the destination and
/// commits with a single atomic rename, mirroring
/// `FeedbackEvidenceBuilder.prepare()`
/// (`Astra/Services/Feedback/FeedbackEvidenceBuilder.swift:34-271`) — cleanup
/// via `defer` is the default outcome, success is the explicit opt-out.
struct WorkspacePackageExporter {
    var fileManager: FileManager = .default
    var appPackageExporter = WorkspaceAppPackageExporter()
    var capabilityLibrary = CapabilityLibrary()
    var packageService = WorkspacePackageService()

    func exportConfigurationPackage(
        workspace: Workspace,
        modelContext: ModelContext,
        to packageURL: URL,
        packageVersion: String = "1.0.0",
        minimumASTRAVersion: String = AppBuildInfo.current.version,
        author: String? = nil,
        createdAt: Date = Date()
    ) throws -> WorkspacePackageExportResult {
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw WorkspacePackageExportError.destinationAlreadyExists(packageURL.path)
        }
        guard var config = WorkspaceConfigManager.export(workspace: workspace, modelContext: modelContext) else {
            throw WorkspacePackageExportError.workspaceConfigUnavailable
        }
        // Configuration-only profile: history and app-mirror rows live only
        // in the embedded .astra-app bundles below, never duplicated here —
        // two representations of the same app that could silently disagree
        // is worse than one.
        config.tasks = nil
        config.workspaceApps = nil
        config.workspaceAppRuns = nil
        config.workspaceAppRunEvents = nil
        config.workspaceAppDependencyBindings = nil
        config.workspaceAppAutomationStates = nil

        // Domain-3 machine-local state must never leave the sender's machine.
        // `additionalPaths`/`activeWorkingPath` are dropped on the import side;
        // these two are dropped here at the source because nothing downstream
        // sanitizes them and the structural content scan does not inspect them:
        //   - `activeExecutionEnvironmentJSON` embeds source/Dockerfile/mount
        //     host paths and credential-projection host paths.
        //   - each SSH connection's `keyPath` is an absolute private-key path
        //     that only resolves on the sender's machine.
        // Capture which SSH connections carried a local key BEFORE blanking, so
        // the manifest's readiness checklist can still tell the recipient which
        // connections need a key re-pointed locally.
        let sshLabelsRequiringLocalKeys = config.sshConnections
            .filter { !$0.keyPath.isEmpty }
            .map(\.displayLabel)
            .sorted()
        config.activeExecutionEnvironmentJSON = nil
        config.sshConnections = config.sshConnections.map { connection in
            var sanitized = connection
            sanitized.keyPath = ""
            return sanitized
        }

        let stagingURL = packageURL.deletingLastPathComponent()
            .appendingPathComponent(".astra-share-staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        try writeJSON(config, to: stagingURL.appendingPathComponent("workspace-config.json"))
        let sourceConfigDigest = try PortablePackageSafeFileReader.digest(
            rootURL: stagingURL,
            relativePath: "workspace-config.json"
        )

        let appEntries = try exportAppEntries(
            workspace: workspace,
            stagingURL: stagingURL,
            minimumASTRAVersion: minimumASTRAVersion,
            createdAt: createdAt
        )
        let capabilityEntries = try exportCapabilityEntries(workspace: workspace, stagingURL: stagingURL)

        let manifest = WorkspacePackageManifest(
            packageID: "\(Self.packageStem(for: workspace.name)).astra-share",
            sourceWorkspaceID: workspace.id.uuidString,
            workspaceName: workspace.name,
            packageVersion: packageVersion,
            minimumASTRAVersion: minimumASTRAVersion,
            exportProfile: .configurationOnly,
            sourceConfigDigest: sourceConfigDigest,
            createdAt: createdAt,
            author: author,
            appEntries: appEntries,
            capabilityEntries: capabilityEntries,
            requiredConnectorServiceTypes: Array(Set((config.connectors ?? []).map(\.serviceType))).sorted(),
            googleAccountsRequiringReauth: (config.googleOAuthAccountProfiles ?? []).map(\.email).sorted(),
            sshConnectionsRequiringLocalKeys: sshLabelsRequiringLocalKeys
        )
        try writeJSON(manifest, to: stagingURL.appendingPathComponent("manifest.json"))

        // Written last so it covers everything written above, including
        // manifest.json itself — matches .astra-app's own convention
        // (WorkspaceAppPackageService.checksums(in:) is likewise computed
        // after package.json/manifest.json are already on disk).
        try writeChecksums(in: stagingURL)

        try selfVerify(stagingURL: stagingURL, expectedConfig: config)

        try fileManager.moveItem(at: stagingURL, to: packageURL)
        published = true
        return WorkspacePackageExportResult(packageURL: packageURL, manifest: manifest)
    }

    // MARK: - Apps

    private func exportAppEntries(
        workspace: Workspace,
        stagingURL: URL,
        minimumASTRAVersion: String,
        createdAt: Date
    ) throws -> [WorkspacePackageAppEntry] {
        guard let modelContext = workspace.modelContext else { return [] }
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceApp>(predicate: #Predicate { $0.workspaceID == workspaceID })
        // Propagate a store/fetch failure rather than swallowing it into an
        // empty list: this profile promises to include every workspace app, and
        // self-verification can't catch the omission because it intentionally
        // expects `workspaceApps` to be absent from the config. A silent
        // downgrade would publish a "complete" package missing all apps.
        let apps = try modelContext.fetch(descriptor)
        guard !apps.isEmpty else { return [] }

        let appsRootURL = stagingURL.appendingPathComponent("apps", isDirectory: true)
        try fileManager.createDirectory(at: appsRootURL, withIntermediateDirectories: true)

        return try apps.map { app in
            let relativeBundlePath = "apps/\(app.logicalID).astra-app"
            let bundleURL = stagingURL.appendingPathComponent(relativeBundlePath, isDirectory: true)
            let result = try appPackageExporter.exportTemplatePackage(
                app: app,
                workspace: workspace,
                minimumASTRAVersion: minimumASTRAVersion,
                mode: .templateOnly,
                createdAt: createdAt,
                to: bundleURL
            )
            let packageDigest = try PortablePackageSafeFileReader.digest(
                rootURL: result.packageURL,
                relativePath: "checksums.json"
            )
            return WorkspacePackageAppEntry(
                logicalID: app.logicalID,
                displayName: app.name,
                relativeBundlePath: relativeBundlePath,
                packageDigest: packageDigest
            )
        }
    }

    // MARK: - Capabilities

    private func exportCapabilityEntries(
        workspace: Workspace,
        stagingURL: URL
    ) throws -> [WorkspacePackageCapabilityEntry] {
        var entries: [WorkspacePackageCapabilityEntry] = []
        var capabilitiesRootCreated = false

        for capabilityID in workspace.enabledCapabilityIDs {
            guard let package = capabilityLibrary.installedPackage(id: capabilityID) else { continue }
            // Mirrors CapabilityGovernance.defaultGovernance's own branch
            // condition exactly, so "what gets embedded" and "what
            // governance would draft" never diverge: built-ins and
            // remote-approved packages are referenced by ID/version only.
            let kind = package.sourceMetadata?.kind
            if kind == "built-in" { continue }
            if kind == "remote", package.sourceMetadata?.trustLevel == "remote-approved" { continue }

            if !capabilitiesRootCreated {
                try fileManager.createDirectory(
                    at: stagingURL.appendingPathComponent("capabilities", isDirectory: true),
                    withIntermediateDirectories: true
                )
                capabilitiesRootCreated = true
            }

            var clamped = package
            CapabilityGovernanceNormalizer.clampToLocalDraft(&clamped)
            // An `.asset` icon points at an on-disk image that
            // `CapabilityLibrary.install` copies from an asset root derived from
            // `sourceMetadata.url` — which the draft clamp above just cleared, so
            // the asset can't travel and import would throw and roll back the
            // whole workspace. Downgrade to the descriptor's own declared
            // fallback symbol so the embedded capability stays self-contained
            // JSON that installs cleanly.
            if clamped.iconDescriptor.kind == .asset {
                clamped.iconDescriptor = .systemSymbol(clamped.iconDescriptor.fallbackSystemName)
            }

            let relativePath = "capabilities/\(capabilityID).json"
            try writeJSON(clamped, to: stagingURL.appendingPathComponent(relativePath))
            let sha256 = try PortablePackageSafeFileReader.digest(rootURL: stagingURL, relativePath: relativePath)

            entries.append(WorkspacePackageCapabilityEntry(
                packageID: capabilityID,
                displayName: clamped.name,
                relativePath: relativePath,
                sha256: sha256
            ))
        }
        return entries
    }

    // MARK: - Checksums

    private func writeChecksums(in stagingURL: URL) throws {
        let paths = PortablePackageSafeFileReader.portableFilePaths(
            in: stagingURL,
            intent: .astraManagedStorage(root: stagingURL),
            fileManager: fileManager
        )
        let checksums = try paths.map { path in
            WorkspacePackageChecksum(
                path: path,
                sha256: try PortablePackageSafeFileReader.digest(rootURL: stagingURL, relativePath: path)
            )
        }
        try writeJSON(checksums, to: stagingURL.appendingPathComponent("checksums.json"))
    }

    // MARK: - Self-verification

    /// Live encode-then-decode-then-compare before this export is allowed to
    /// publish, mirroring `FeedbackEvidenceBuilder.swift:174-223` — a
    /// stronger guarantee than a fixture test alone, since both the writer
    /// and reader run for real on every export, not just in CI against a
    /// hand-typed literal. (`LegacyWorkspaceCanvasItemPreferenceMigration.swift`'s
    /// PR #321 postmortem is exactly the failure mode this closes: a reader
    /// that silently stopped matching its writer, caught only by a fixture
    /// test trusting the old shape on faith.)
    private func selfVerify(stagingURL: URL, expectedConfig: WorkspaceConfigManager.WorkspaceConfig) throws {
        let report = packageService.validatePackage(at: stagingURL)
        guard report.canInstall, let decodedConfig = report.workspaceConfig else {
            throw WorkspacePackageExportError.selfVerificationFailed(report.blockers)
        }

        var mismatches: [PortablePackageValidationIssue] = []
        func expect(_ condition: Bool, _ field: String) {
            guard !condition else { return }
            mismatches.append(PortablePackageValidationIssue(
                severity: .blocker,
                path: "/workspace-config.json/\(field)",
                message: "Round-trip mismatch: decoded package does not match the in-memory export."
            ))
        }
        expect(decodedConfig.name == expectedConfig.name, "name")
        expect(decodedConfig.instructions == expectedConfig.instructions, "instructions")
        expect(
            Set(decodedConfig.enabledCapabilityIDs ?? []) == Set(expectedConfig.enabledCapabilityIDs ?? []),
            "enabledCapabilityIDs"
        )
        expect(decodedConfig.skills.count == expectedConfig.skills.count, "skills")
        expect((decodedConfig.connectors ?? []).count == (expectedConfig.connectors ?? []).count, "connectors")
        expect((decodedConfig.localTools ?? []).count == (expectedConfig.localTools ?? []).count, "localTools")
        expect(decodedConfig.tasks == nil, "tasks")
        expect(decodedConfig.workspaceApps == nil, "workspaceApps")

        guard mismatches.isEmpty else {
            throw WorkspacePackageExportError.selfVerificationFailed(mismatches)
        }
    }

    // MARK: - Helpers

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func packageStem(for workspaceName: String) -> String {
        let sanitized = workspaceName.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_") ? Character(scalar) : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed.lowercased()
    }
}
