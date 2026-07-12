import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct WorkspaceCreationResult {
    let workspace: Workspace
    /// True when the workspace itself was created but at least one selected
    /// capability's credential could not be saved (e.g. a denied Keychain
    /// prompt) — the workspace is usable, just missing that secret.
    let hasCapabilityEnableFailures: Bool
}

struct WorkspaceImportResult {
    let imported: [Workspace]

    var selectedWorkspace: Workspace? {
        imported.last
    }
}

@MainActor
struct ContentWorkspaceActionCoordinator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue
    let workspacesRoot: String

    var resolvedRoot: String {
        if !workspacesRoot.isEmpty { return workspacesRoot }
        return AppChannel.current.defaultWorkspacesRoot
    }

    func createWorkspace(from draft: NewWorkspaceDraft, source: String) -> WorkspaceCreationResult? {
        guard draft.canCreate else { return nil }

        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: taskQueue)
        let workspace = coordinator.createWorkspace(name: draft.trimmedName, rootPath: resolvedRoot)
        workspace.instructions = draft.trimmedInstructions
        // Checkpoint the instructions before applying capabilities: a failed
        // capability enable calls modelContext.rollback(), which reverts
        // every uncommitted change in the context back to the last save —
        // without this save, that would also discard the instructions set
        // above since they were never committed. Auto-exports rather than
        // using saveWithoutAutoExport: unlike that helper's documented
        // "superseded by a later save-and-export" contract, there is no
        // guaranteed later export here — no capabilities may be selected,
        // or every selected one may fail, in which case this is the only
        // save that ever runs, and the workspace's JSON mirror must not be
        // left with the pre-instructions snapshot TaskLifecycleCoordinator
        // .createWorkspace already exported.
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: workspace,
            modelContext: modelContext,
            auditFields: ["operation": "save_workspace_instructions"]
        )
        let hasCapabilityEnableFailures = applyNewWorkspaceCapabilities(to: workspace, from: draft, source: source)
        return WorkspaceCreationResult(workspace: workspace, hasCapabilityEnableFailures: hasCapabilityEnableFailures)
    }

    func importWorkspaces(
        from urls: [URL],
        existingWorkspaces: [Workspace],
        askDuplicateAction: (String, Int) -> TaskLifecycleCoordinator.DuplicateAction
    ) -> WorkspaceImportResult {
        WorkspaceImportOrchestrator(modelContext: modelContext, taskQueue: taskQueue)
            .importWorkspaces(
                from: urls,
                existingWorkspaces: existingWorkspaces,
                askDuplicateAction: askDuplicateAction
            )
    }

    /// Returns whether at least one selected capability failed to enable
    /// (most commonly a denied/failed Keychain credential save) so the
    /// caller can surface that to the user instead of reporting unqualified
    /// success — see `WorkspaceCreationResult.hasCapabilityEnableFailures`.
    @discardableResult
    private func applyNewWorkspaceCapabilities(to workspace: Workspace, from draft: NewWorkspaceDraft, source: String) -> Bool {
        let selectedIDs = draft.selectedCapabilityIDs
        guard !selectedIDs.isEmpty else { return false }

        var packagesByID: [String: PluginPackage] = [:]
        for package in PluginCatalog.builtInPackages {
            packagesByID[package.id] = package
        }
        let packages = OnboardingCapabilitySetup.configurableOptions.compactMap { option -> PluginPackage? in
            guard let packageID = option.packageID, selectedIDs.contains(packageID) else { return nil }
            return packagesByID[packageID]
        }
        guard !packages.isEmpty else { return false }

        let installer = CapabilityInstaller()
        let policyContext = CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: CapabilityApprovalStore().records()
        )
        var hasFailure = false
        var enabledAnyCapability = false
        for package in packages {
            let inputs = draft.capabilityConfiguration.installationInputs(for: package.id)
            let traceID = AuditTrace.make("workspace-capability")
            AppLogger.breadcrumb(action: "onboarding_capability_enable_selected", category: "Capabilities", traceID: traceID, fields: [
                "source": source,
                "package_id": package.id,
                "package_name": package.name,
                "workspace_id": workspace.id.uuidString,
                "credential_input_count": String(inputs.credentialInputs.count),
                "config_input_count": String(inputs.configInputs.count),
                "base_url_override_count": String(inputs.baseURLOverrides.count)
            ])
            do {
                try installer.install(
                    package,
                    into: workspace,
                    modelContext: modelContext,
                    credentialInputs: inputs.credentialInputs,
                    configInputs: inputs.configInputs,
                    baseURLOverrides: inputs.baseURLOverrides,
                    allowCredentialUserInteraction: inputs.credentialInputs.values.contains { !$0.isEmpty },
                    policyContext: policyContext,
                    traceID: traceID
                )
                enabledAnyCapability = true
            } catch {
                hasFailure = true
                AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                    "source": source,
                    "trace_id": traceID,
                    "package_id": package.id,
                    "package_name": package.name,
                    "package_version": package.version,
                    "workspace_id": workspace.id.uuidString,
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
        if enabledAnyCapability {
            // Each installer call owns its global library mutation event. The
            // workspace projection changed as one onboarding action, so emit a
            // single scoped invalidation after the batch completes.
            CapabilityCatalogPersistenceEvents.post(.workspace(workspace.id))
        }
        return hasFailure
    }
}

@MainActor
struct WorkspaceImportOrchestrator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue

    func importWorkspaces(
        from urls: [URL],
        existingWorkspaces: [Workspace],
        askDuplicateAction: (String, Int) -> TaskLifecycleCoordinator.DuplicateAction
    ) -> WorkspaceImportResult {
        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: taskQueue)
        var imported: [Workspace] = []
        var knownWorkspaces = existingWorkspaces

        for candidate in WorkspaceImportDiscovery.candidates(for: urls) {
            let workspace: Workspace?
            if let configURL = candidate.configURL {
                workspace = coordinator.importFromConfig(
                    at: configURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            } else {
                workspace = coordinator.createWorkspaceFromFolder(
                    candidate.folderURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            }

            if let workspace {
                imported.append(workspace)
                knownWorkspaces.append(workspace)
            }
        }

        for workspace in imported {
            coordinator.importSessionsIfNeeded(for: workspace)
        }

        WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext,
            auditFields: ["operation": "save_imported_workspaces"]
        )

        for workspace in imported {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }

        if !imported.isEmpty {
            AppLogger.audit(.workspaceImported, category: "App", fields: [
                "workspace_count": String(imported.count)
            ])
        }

        return WorkspaceImportResult(imported: imported)
    }
}
