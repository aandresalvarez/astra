import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// File publication entry points, including prior credential-proof admission.
extension WorkspaceConfigManager {
    public static func exportToFile(workspace: Workspace, modelContext: ModelContext, url: URL) throws {
        if PluginCredentialEvidenceUpgrade.isOwnMirror(url, workspace: workspace) {
            try PluginCredentialEvidenceUpgrade.admit(workspace: workspace, context: modelContext)
        }
        guard let config = export(workspace: workspace, modelContext: modelContext) else { return }
        try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        try write(config, to: url)
    }

    @discardableResult
    public static func exportToFileResult(workspace: Workspace, modelContext: ModelContext, url: URL) -> WorkspaceConfigExportResult {
        do {
            if PluginCredentialEvidenceUpgrade.isOwnMirror(url, workspace: workspace) {
                try PluginCredentialEvidenceUpgrade.admit(workspace: workspace, context: modelContext)
            }
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspace.id.uuidString, url: url, error: error)
        }
        guard let config = export(workspace: workspace, modelContext: modelContext) else {
            return exportResult(
                status: .skippedNoConfig,
                workspaceID: workspace.id.uuidString,
                url: url,
                error: nil
            )
        }
        do {
            try prepareMirrorParentIfNeeded(workspace: workspace, url: url)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspace.id.uuidString, url: url, error: error)
        }
        return writeResult(config, workspaceID: workspace.id.uuidString, to: url)
    }

    public static func autoExport(workspace: Workspace, modelContext: ModelContext) {
        autoExport(workspace: workspace, modelContext: modelContext) {
            export(workspace: workspace, modelContext: modelContext)
        }
    }

    // The preparation boundary can fail before a replacement snapshot exists.
    // Keep the prior queued write alive until the replacement file lands.
    @discardableResult
    static func autoExport(workspace: Workspace, modelContext: ModelContext,
                           writer: WorkspaceAutoExportWriter = .shared,
                           makeSnapshot: () -> WorkspaceConfig?) -> Task<Bool, Never>? {
        let workspaceID = workspace.id.uuidString
        guard !workspace.isDeleted else {
            WorkspaceAutoExportGate.shared.retire(workspaceID: workspaceID)
            return nil
        }
        let target = autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logAutoExportSkipped(workspace: workspace, reason: target.reason)
            return nil
        }
        do {
            try PluginCredentialEvidenceUpgrade.admit(workspace: workspace, context: modelContext)
        } catch {
            logAutoExportSkipped(workspace: workspace, reason: "credential_evidence_admission_failed")
            return nil
        }
        guard let config = makeSnapshot() else { return nil }
        // Recorded before the mirror lands, so recovery after a lost store
        // probes this folder even when no scanned root holds it. A folder
        // that can't be recorded gets no mirror: one recovery can't find
        // would hold owners a trusted cleanup never counts.
        guard WorkspaceMirrorRegistry(for: modelContext)?.register([workspace.primaryPath]) ?? true else {
            logAutoExportSkipped(workspace: workspace, reason: "mirror_registry_unwritable")
            return nil
        }
        let ticket = WorkspaceAutoExportGate.shared.reserveExport(for: workspaceID)
        return Task.detached(priority: .utility) {
            await writer.write(config, to: url, workspaceID: workspaceID, ticket: ticket)
        }
    }

    public struct AutoExportTarget {
        public let url: URL?
        public let reason: String
    }

    public static func autoExportTarget(for workspacePath: String) -> AutoExportTarget {
        guard !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AutoExportTarget(url: nil, reason: "primary_path_empty")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AutoExportTarget(url: nil, reason: "primary_path_unavailable")
        }

        let configPath = WorkspaceFileLayout.workspaceConfigFile(for: workspacePath)
        guard !configPath.isEmpty else {
            return AutoExportTarget(url: nil, reason: "config_path_empty")
        }
        let supportPath = WorkspaceFileLayout.supportDirectory(for: workspacePath)
        do {
            try FileManager.default.createDirectory(
                atPath: supportPath,
                withIntermediateDirectories: true
            )
            try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspacePath)
        } catch {
            return AutoExportTarget(url: nil, reason: "support_directory_unavailable")
        }

        return AutoExportTarget(url: URL(fileURLWithPath: configPath), reason: "ready")
    }

    private static func logAutoExportSkipped(workspace: Workspace, reason: String) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
            "result": "auto_export_skipped",
            "reason": reason,
            "workspace_id": workspace.id.uuidString
        ], level: .debug)
    }

    private static func exportResult(
        status: WorkspaceConfigExportResult.Status,
        workspaceID: String,
        url: URL,
        error: Error?
    ) -> WorkspaceConfigExportResult {
        let nsError = error.map { $0 as NSError }
        let parent = url.deletingLastPathComponent()
        return WorkspaceConfigExportResult(
            status: status,
            workspaceID: workspaceID,
            path: url.path,
            errorType: error.map { String(describing: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription,
            parentExists: FileManager.default.fileExists(atPath: parent.path),
            parentWritable: FileManager.default.isWritableFile(atPath: parent.path)
        )
    }

    static func writeResult(_ config: WorkspaceConfig, workspaceID: String, to url: URL) -> WorkspaceConfigExportResult {
        do {
            try write(config, to: url)
            return exportResult(status: .exported, workspaceID: workspaceID, url: url, error: nil)
        } catch {
            return exportResult(status: .writeFailed, workspaceID: workspaceID, url: url, error: error)
        }
    }

    private static func prepareMirrorParentIfNeeded(workspace: Workspace, url: URL) throws {
        let mirrorURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))
            .standardizedFileURL
        guard url.standardizedFileURL.path == mirrorURL.path else { return }
        try FileManager.default.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WorkspaceGeneratedStateExcluder.ensureExcluded(workspacePath: workspace.primaryPath)
    }
}
