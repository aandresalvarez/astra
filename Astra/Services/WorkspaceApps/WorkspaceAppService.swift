import CryptoKit
import Foundation
import SwiftData

enum WorkspaceAppServiceError: LocalizedError, Equatable {
    case invalidManifest([WorkspaceAppManifestValidationReport.Issue])
    case emptyWorkspacePath
    case encodeFailed(String)
    case storageFailed(String)
    case missingManifest(String)
    case fileOperationFailed(String)
    case missingDependencyBinding(String)
    case missingAutomation(String)
    case missingContractImplementation(String)
    case incompatibleContractImplementation(requirementID: String, implementationID: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app manifest is invalid.\n\(messages)"
        case .emptyWorkspacePath:
            return "Workspace path is empty."
        case .encodeFailed(let message):
            return "Could not encode workspace app manifest: \(message)"
        case .storageFailed(let message):
            return "Could not initialize workspace app storage: \(message)"
        case .missingManifest(let path):
            return "Workspace app manifest is missing at \(path)."
        case .fileOperationFailed(let message):
            return "Workspace app file operation failed: \(message)"
        case .missingDependencyBinding(let requirementID):
            return "Workspace app dependency requirement '\(requirementID)' was not found."
        case .missingAutomation(let automationID):
            return "Workspace app automation '\(automationID)' was not found."
        case .missingContractImplementation(let implementationID):
            return "Workspace app contract implementation '\(implementationID)' was not found."
        case .incompatibleContractImplementation(let requirementID, let implementationID):
            return "Contract implementation '\(implementationID)' does not satisfy requirement '\(requirementID)'."
        }
    }
}

struct WorkspaceAppCreationResult {
    var app: WorkspaceApp
    var manifestURL: URL
    /// The manifest as PERSISTED — may differ from the caller's input (e.g. `createApp` auto-suffixed
    /// a duplicate logical id). Downstream (version snapshot, package storage seed) must use THIS, not
    /// the pre-call manifest, so metadata/data match the app's actual id + storage path.
    var manifest: WorkspaceAppManifest
}

struct WorkspaceAppService {
    var fileManager: FileManager = .default
    var storageService = WorkspaceAppStorageService()
    var contractRegistry = WorkspaceAppContractRegistry()
    var automationScheduler = WorkspaceAppAutomationScheduler()

    @MainActor
    func createApp(
        manifest: WorkspaceAppManifest,
        in workspace: Workspace,
        modelContext: ModelContext,
        status: WorkspaceAppLifecycleStatus = .draft,
        sourcePackageID: String? = nil,
        sourcePackageVersion: String? = nil,
        sourcePackageDigest: String? = nil
    ) throws -> WorkspaceAppCreationResult {
        let report = WorkspaceAppManifestValidator.validate(manifest)
        guard report.isValid else {
            throw WorkspaceAppServiceError.invalidManifest(report.blockers)
        }
        guard !workspace.primaryPath.isEmpty else {
            throw WorkspaceAppServiceError.emptyWorkspacePath
        }

        // Guarantee a workspace-unique logical ID at the SERVICE boundary, not just in callers. The
        // logical ID keys the app's storage directory + SQLite file (`WorkspaceFileLayout`), so two
        // apps sharing one would share `.astra/apps/<id>/data/app.sqlite` — a cross-app data-isolation
        // break. Auto-suffix a collision and keep `manifest.app.id` in lockstep so the persisted
        // manifest matches its storage path. Callers that already dedupe pass a unique id, so this is
        // a no-op for them; a caller that forgets can no longer collide two apps onto one database.
        var manifest = manifest
        let existing = try existingLogicalIDs(in: workspace, modelContext: modelContext)
        let appID = uniqueLogicalID(base: manifest.app.id, existingLogicalIDs: existing)
        if appID != manifest.app.id {
            manifest.app.id = appID
        }
        guard let dataDirectoryURL = WorkspaceFileLayout.appDataDirectoryURL(
                workspacePath: workspace.primaryPath,
                appID: appID
              ),
              let manifestURL = WorkspaceFileLayout.appManifestFileURL(
                workspacePath: workspace.primaryPath,
                appID: appID
              ),
              let databaseURL = WorkspaceFileLayout.appDatabaseFileURL(
                workspacePath: workspace.primaryPath,
                appID: appID
              ) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve safe storage path for app '\(appID)'.")
        }
        try fileManager.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)

        let manifestData: Data
        do {
            manifestData = try Self.encodeManifest(manifest)
        } catch {
            throw WorkspaceAppServiceError.encodeFailed(String(describing: error))
        }
        try manifestData.write(to: manifestURL, options: [.atomic])
        if let storage = manifest.storage {
            do {
                try storageService.applySchema(storage, databaseURL: databaseURL)
            } catch {
                throw WorkspaceAppServiceError.storageFailed(String(describing: error))
            }
        }

        let now = Date()
        let app = WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: appID,
            name: manifest.app.name,
            icon: manifest.app.icon,
            appDescription: manifest.app.description,
            lifecycleStatus: status,
            permissionMode: manifest.permissions.defaultMode,
            dependencyStatus: .ready,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: appID),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: appID),
            manifestDigest: Self.digest(for: manifestData),
            sourcePackageID: sourcePackageID,
            sourcePackageVersion: sourcePackageVersion,
            sourcePackageDigest: sourcePackageDigest,
            createdAt: now,
            updatedAt: now
        )
        let bindings = dependencyBindings(
            for: manifest.requirements,
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: appID,
            now: now,
            registry: registry(for: workspace)
        )
        let automations = automationStates(
            for: manifest.automations,
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: appID,
            now: now
        )
        app.dependencyStatus = dependencyStatus(for: bindings)
        modelContext.insert(app)
        for binding in bindings {
            modelContext.insert(binding)
        }
        for automation in automations {
            modelContext.insert(automation)
        }
        workspace.updatedAt = now
        try modelContext.save()

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_manifest",
            "result": "created",
            "workspace_id": workspace.id.uuidString,
            "app_id": appID,
            "manifest": manifestURL.lastPathComponent
        ])

        return WorkspaceAppCreationResult(app: app, manifestURL: manifestURL, manifest: manifest)
    }

    /// Version-in-place: rewrite an EXISTING app's manifest + storage, keeping the SAME logicalID and
    /// SQLite database. This is what "Edit in Studio → Publish" uses so editing an app UPDATES it (the
    /// caller then snapshots a new version) instead of forking a suffixed sibling. Storage schema is
    /// applied additively (the existing rows are preserved); dependency bindings are reconciled to the
    /// new requirements; automation states are reconciled while PRESERVING each surviving automation's
    /// enabled state. The logical id is forced to the app's — an edit never changes identity.
    @MainActor
    @discardableResult
    func updateApp(
        _ app: WorkspaceApp,
        manifest rawManifest: WorkspaceAppManifest,
        in workspace: Workspace,
        modelContext: ModelContext,
        status: WorkspaceAppLifecycleStatus = .published,
        now: Date = Date()
    ) throws -> WorkspaceAppCreationResult {
        guard !workspace.primaryPath.isEmpty else { throw WorkspaceAppServiceError.emptyWorkspacePath }
        guard app.workspaceID == workspace.id else {
            throw WorkspaceAppServiceError.fileOperationFailed(
                "App '\(app.logicalID)' does not belong to workspace '\(workspace.id.uuidString)'."
            )
        }
        var manifest = rawManifest
        manifest.app.id = app.logicalID   // identity is fixed — an edit never changes the logical id

        // Validate the forced manifest before any write (mirrors createApp) — an edit can't publish a
        // structurally invalid app over a working one.
        let report = WorkspaceAppManifestValidator.validate(manifest)
        guard report.isValid else { throw WorkspaceAppServiceError.invalidManifest(report.blockers) }

        guard let dataDirectoryURL = WorkspaceFileLayout.appDataDirectoryURL(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ),
              let manifestURL = WorkspaceFileLayout.appManifestFileURL(
                workspacePath: workspace.primaryPath,
                appID: app.logicalID
              ),
              let databaseURL = WorkspaceFileLayout.appDatabaseFileURL(
                workspacePath: workspace.primaryPath,
                appID: app.logicalID
              ) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve safe storage path for app '\(app.logicalID)'.")
        }
        let manifestData: Data
        do {
            manifestData = try Self.encodeManifest(manifest)
        } catch {
            throw WorkspaceAppServiceError.encodeFailed(String(describing: error))
        }
        try fileManager.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
        // Migrate the DB FIRST (additive: new tables + ADD COLUMN), THEN write the manifest — so a
        // failed migration never leaves manifest.json describing a schema the database lacks.
        if let storage = manifest.storage {
            // Block a DESTRUCTIVE/ambiguous in-place schema change (drop table/column, change a type or
            // primary key, tighten a required constraint) — applySchema is additive-only, so accepting
            // one would silently drift manifest.json from the SQLite file. Additive adds proceed; the
            // user forks via Save as a Copy for a structural change.
            let currentStorage = (try? WorkspaceAppManifestStore(fileManager: fileManager)
                .loadManifest(app: app, workspace: workspace).manifest)?.storage
            let blockedKinds: Set<WorkspaceAppStorageMigrationStep.Kind> =
                [.dropTable, .dropColumn, .changeColumnType, .changePrimaryKey, .changeRequiredConstraint]
            if let blocked = storageService.planMigration(from: currentStorage, to: storage)
                .steps.first(where: { blockedKinds.contains($0.kind) }) {
                throw WorkspaceAppServiceError.storageFailed(
                    "This change can't be applied to the existing data in place: \(blocked.summary) Use Save as a Copy to start a new app with the new schema."
                )
            }
            do {
                try storageService.applySchema(storage, databaseURL: databaseURL)
            } catch {
                throw WorkspaceAppServiceError.storageFailed(String(describing: error))
            }
        }
        try manifestData.write(to: manifestURL, options: [.atomic])

        app.name = manifest.app.name
        app.icon = manifest.app.icon
        app.appDescription = manifest.app.description
        app.permissionMode = manifest.permissions.defaultMode
        app.lifecycleStatus = status
        app.manifestDigest = Self.digest(for: manifestData)
        app.updatedAt = now

        let appPK = app.id

        // Reconcile dependency bindings by requirementID: PRESERVE an unchanged requirement's binding
        // (keeping the user-selected implementation from remapDependencyBinding), drop bindings for
        // removed requirements, and (re)create only new or contract-changed ones.
        let existingBindings = try modelContext.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate<WorkspaceAppDependencyBinding> { $0.appID == appPK }
        ))
        let bindingByReq = Dictionary(existingBindings.map { ($0.requirementID, $0) }, uniquingKeysWith: { first, _ in first })
        let newRequirementIDs = Set(manifest.requirements.map(\.id))
        for binding in existingBindings where !newRequirementIDs.contains(binding.requirementID) {
            modelContext.delete(binding)
        }
        var reconciledBindings: [WorkspaceAppDependencyBinding] = []
        for requirement in manifest.requirements {
            if let prior = bindingByReq[requirement.id], prior.contract == requirement.contract,
               prior.operations == requirement.operations, prior.optional == requirement.optional {
                reconciledBindings.append(prior)   // unchanged → keep the user's mapping
            } else {
                if let prior = bindingByReq[requirement.id] { modelContext.delete(prior) }   // changed → replace
                if let fresh = dependencyBindings(for: [requirement], workspaceID: workspace.id, appID: app.id, appLogicalID: app.logicalID, now: now, registry: registry(for: workspace)).first {
                    modelContext.insert(fresh)
                    reconciledBindings.append(fresh)
                }
            }
        }
        app.dependencyStatus = dependencyStatus(for: reconciledBindings)

        // Reconcile automations by id: keep a surviving automation, but if its type/action MATERIALLY
        // changed, force it back to disabled (an enabled schedule must not silently run a different
        // action); drop removed ones; add new ones disabled.
        let existingAutomations = try modelContext.fetch(FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate<WorkspaceAppAutomationState> { $0.appID == appPK }
        ))
        var automationByID = Dictionary(existingAutomations.map { ($0.automationID, $0) }, uniquingKeysWith: { first, _ in first })
        let newAutomationIDs = Set(manifest.automations.map(\.id))
        for automation in existingAutomations where !newAutomationIDs.contains(automation.automationID) {
            modelContext.delete(automation)
            automationByID[automation.automationID] = nil
        }
        for spec in manifest.automations {
            if let surviving = automationByID[spec.id] {
                if surviving.automationType != spec.type || surviving.actionID != spec.action {
                    surviving.automationType = spec.type
                    surviving.actionID = spec.action
                    surviving.isEnabled = false
                    surviving.status = .disabled
                }
                surviving.updatedAt = now
            } else {
                modelContext.insert(WorkspaceAppAutomationState(
                    workspaceID: workspace.id, appID: app.id, appLogicalID: app.logicalID,
                    automationID: spec.id, automationType: spec.type, actionID: spec.action,
                    isEnabled: false, status: .disabled, createdAt: now, updatedAt: now
                ))
            }
        }

        workspace.updatedAt = now
        try modelContext.save()

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_manifest",
            "result": "updated",
            "workspace_id": workspace.id.uuidString,
            "app_id": app.logicalID,
            "manifest": manifestURL.lastPathComponent
        ])

        return WorkspaceAppCreationResult(app: app, manifestURL: manifestURL, manifest: manifest)
    }

    /// The contract registry for a workspace: the built-ins PLUS the contract families + implementations
    /// contributed by the workspace's ENABLED capabilities (their app-read CLI tools). Used at publish so
    /// an app's requirement on a capability-contributed contract auto-maps to a `.mapped` binding — the
    /// "enable a capability → apps can use it" path, with no per-connector Swift.
    func registry(for workspace: Workspace) -> WorkspaceAppContractRegistry {
        let derived = WorkspaceAppCapabilityContractDeriver.derived(for: workspace)
        return contractRegistry.including(capabilityFamilies: derived.families, implementations: derived.implementations)
    }

    /// Preview-only: synthesize the SAME `.mapped` dependency bindings the publish path computes, for a
    /// TRANSIENT (un-persisted) draft app id, so the App Studio preview can resolve live `astra.read`
    /// connector reads before publishing. Reads nothing from SwiftData. MUST use `registry(for:)` (the
    /// built-ins PLUS the workspace's enabled-capability families) so the preview maps EXACTLY what a
    /// published app with the same requirements would — no privilege escalation, no silent under-mapping.
    func previewDependencyBindings(
        for requirements: [WorkspaceAppRequirement],
        workspace: Workspace,
        appID: UUID,
        appLogicalID: String
    ) -> [WorkspaceAppDependencyBinding] {
        dependencyBindings(
            for: requirements,
            workspaceID: workspace.id,
            appID: appID,
            appLogicalID: appLogicalID,
            now: Date(),
            registry: registry(for: workspace)
        )
    }

    private func dependencyBindings(
        for requirements: [WorkspaceAppRequirement],
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        now: Date,
        registry: WorkspaceAppContractRegistry? = nil
    ) -> [WorkspaceAppDependencyBinding] {
        (registry ?? contractRegistry).resolveAll(requirements).map { resolution in
            let selected = resolution.selectedImplementation
            return WorkspaceAppDependencyBinding(
                workspaceID: workspaceID,
                appID: appID,
                appLogicalID: appLogicalID,
                requirementID: resolution.requirement.id,
                contract: resolution.requirement.contract,
                operations: resolution.requirement.operations,
                optional: resolution.requirement.optional,
                status: bindingStatus(for: resolution),
                implementationID: selected?.id,
                provider: selected?.provider,
                transport: selected?.transport,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private func automationStates(
        for automations: [WorkspaceAppAutomationSpec],
        workspaceID: UUID,
        appID: UUID,
        appLogicalID: String,
        now: Date
    ) -> [WorkspaceAppAutomationState] {
        automations.map { automation in
            WorkspaceAppAutomationState(
                workspaceID: workspaceID,
                appID: appID,
                appLogicalID: appLogicalID,
                automationID: automation.id,
                automationType: automation.type,
                actionID: automation.action,
                isEnabled: false,
                status: .disabled,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    private func bindingStatus(
        for resolution: WorkspaceAppContractResolution
    ) -> WorkspaceAppDependencyBindingStatus {
        if resolution.selectedImplementation != nil {
            return .mapped
        }
        return resolution.requirement.optional ? .optionalMissing : .missingRequired
    }

    private func dependencyStatus(
        for bindings: [WorkspaceAppDependencyBinding]
    ) -> WorkspaceAppDependencyStatus {
        guard !bindings.isEmpty else { return .ready }
        if bindings.contains(where: { $0.status == .missingRequired }) {
            return .missingRequired
        }
        return .ready
    }

    @MainActor
    func openApp(
        _ app: WorkspaceApp,
        in workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        app.lastOpenedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app",
            "result": "opened",
            "app_id": app.logicalID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func refreshApp(
        _ app: WorkspaceApp,
        in workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        app.lastRefreshedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app",
            "result": "refreshed",
            "app_id": app.logicalID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func duplicateApp(
        _ app: WorkspaceApp,
        in workspace: Workspace,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws -> WorkspaceAppCreationResult {
        guard !workspace.primaryPath.isEmpty else {
            throw WorkspaceAppServiceError.emptyWorkspacePath
        }
        let manifestStore = WorkspaceAppManifestStore(fileManager: fileManager)
        guard let sourceDirectory = manifestStore.appDirectoryURL(app: app, workspace: workspace),
              let sourceManifestURL = manifestStore.readableManifestURL(app: app, workspace: workspace) else {
            throw WorkspaceAppServiceError.fileOperationFailed("No safe app manifest path for app '\(app.logicalID)'.")
        }
        guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw WorkspaceAppServiceError.missingManifest(sourceManifestURL.path)
        }

        var manifest: WorkspaceAppManifest
        do {
            manifest = try JSONDecoder().decode(
                WorkspaceAppManifest.self,
                from: Data(contentsOf: sourceManifestURL)
            )
        } catch {
            throw WorkspaceAppServiceError.fileOperationFailed(String(describing: error))
        }

        let existingLogicalIDs = try existingLogicalIDs(in: workspace, modelContext: modelContext)
        let baseID = "\(manifest.app.id)-copy"
        let logicalID = uniqueLogicalID(base: baseID, existingLogicalIDs: existingLogicalIDs)
        manifest.app.id = logicalID
        manifest.app.name = uniqueDisplayName(base: "\(manifest.app.name) Copy", existingNames: try existingNames(in: workspace, modelContext: modelContext))

        guard let destinationDirectory = WorkspaceFileLayout.appDirectoryURL(
            workspacePath: workspace.primaryPath,
            appID: logicalID
        ) else {
            throw WorkspaceAppServiceError.fileOperationFailed("Could not resolve safe storage path for app '\(logicalID)'.")
        }
        do {
            try fileManager.copyItem(at: sourceDirectory, to: destinationDirectory)
            let manifestData = try Self.encodeManifest(manifest)
            try manifestData.write(
                to: destinationDirectory.appendingPathComponent("manifest.json"),
                options: [.atomic]
            )
            let duplicate = WorkspaceApp(
                workspaceID: workspace.id,
                logicalID: logicalID,
                name: manifest.app.name,
                icon: manifest.app.icon,
                appDescription: manifest.app.description,
                lifecycleStatus: app.lifecycleStatus,
                permissionMode: manifest.permissions.defaultMode,
                dependencyStatus: .ready,
                manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: logicalID),
                appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: logicalID),
                manifestDigest: Self.digest(for: manifestData),
                sourcePackageID: app.sourcePackageID,
                sourcePackageVersion: app.sourcePackageVersion,
                sourcePackageDigest: app.sourcePackageDigest,
                createdAt: now,
                updatedAt: now
            )
            let bindings = dependencyBindings(
                for: manifest.requirements,
                workspaceID: workspace.id,
                appID: duplicate.id,
                appLogicalID: logicalID,
                now: now,
                registry: registry(for: workspace)
            )
            let automations = automationStates(
                for: manifest.automations,
                workspaceID: workspace.id,
                appID: duplicate.id,
                appLogicalID: logicalID,
                now: now
            )
            duplicate.dependencyStatus = dependencyStatus(for: bindings)
            modelContext.insert(duplicate)
            bindings.forEach(modelContext.insert)
            automations.forEach(modelContext.insert)
            workspace.updatedAt = now
            try modelContext.save()
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

            AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
                "resource": "workspace_app",
                "result": "duplicated",
                "source_app_id": app.logicalID,
                "app_id": duplicate.logicalID,
                "workspace_id": workspace.id.uuidString
            ])

            return WorkspaceAppCreationResult(
                app: duplicate,
                manifestURL: destinationDirectory.appendingPathComponent("manifest.json"),
                manifest: manifest
            )
        } catch {
            try? fileManager.removeItem(at: destinationDirectory)
            throw WorkspaceAppServiceError.fileOperationFailed(String(describing: error))
        }
    }

    @MainActor
    func deleteApp(
        _ app: WorkspaceApp,
        in workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        if let workspace, !workspace.primaryPath.isEmpty {
            let directory = WorkspaceAppManifestStore(fileManager: fileManager)
                .appDirectoryURL(app: app, workspace: workspace)
            if let directory,
               WorkspaceFileLayout.isContainedStoredAppDirectory(directory, workspacePath: workspace.primaryPath),
               fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.removeItem(at: directory)
                } catch {
                    throw WorkspaceAppServiceError.fileOperationFailed(String(describing: error))
                }
            }
        }

        let appID = app.id
        for binding in try modelContext.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate<WorkspaceAppDependencyBinding> { $0.appID == appID }
        )) {
            modelContext.delete(binding)
        }
        for automation in try modelContext.fetch(FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate<WorkspaceAppAutomationState> { $0.appID == appID }
        )) {
            modelContext.delete(automation)
        }
        for event in try modelContext.fetch(FetchDescriptor<WorkspaceAppRunEvent>(
            predicate: #Predicate<WorkspaceAppRunEvent> { $0.appID == appID }
        )) {
            modelContext.delete(event)
        }
        for run in try modelContext.fetch(FetchDescriptor<WorkspaceAppRun>(
            predicate: #Predicate<WorkspaceAppRun> { $0.appID == appID }
        )) {
            modelContext.delete(run)
        }
        modelContext.delete(app)
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app",
            "result": "deleted",
            "app_id": app.logicalID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func dependencyBindings(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppDependencyBinding] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppDependencyBinding>(
            predicate: #Predicate<WorkspaceAppDependencyBinding> { binding in
                binding.appID == appID
            },
            sortBy: [SortDescriptor(\.requirementID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    func remapDependencyBinding(
        app: WorkspaceApp,
        requirementID: String,
        implementationID: String?,
        workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        let bindings = try dependencyBindings(for: app, modelContext: modelContext)
        guard let binding = bindings.first(where: { $0.requirementID == requirementID }) else {
            throw WorkspaceAppServiceError.missingDependencyBinding(requirementID)
        }

        if let implementationID {
            guard let implementation = contractRegistry.implementation(id: implementationID) else {
                throw WorkspaceAppServiceError.missingContractImplementation(implementationID)
            }
            guard contractRegistry.satisfies(binding: binding, implementation: implementation) else {
                throw WorkspaceAppServiceError.incompatibleContractImplementation(
                    requirementID: requirementID,
                    implementationID: implementationID
                )
            }
            binding.status = .mapped
            binding.implementationID = implementation.id
            binding.provider = implementation.provider
            binding.transport = implementation.transport
        } else {
            binding.status = binding.optional ? .optionalMissing : .missingRequired
            binding.implementationID = nil
            binding.provider = nil
            binding.transport = nil
        }

        binding.updatedAt = now
        app.dependencyStatus = dependencyStatus(for: bindings)
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_dependency_binding",
            "result": "remapped",
            "app_id": app.logicalID,
            "requirement_id": requirementID,
            "implementation_id": implementationID ?? "none",
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    @MainActor
    func automationStates(
        for app: WorkspaceApp,
        modelContext: ModelContext
    ) throws -> [WorkspaceAppAutomationState] {
        let appID = app.id
        let descriptor = FetchDescriptor<WorkspaceAppAutomationState>(
            predicate: #Predicate<WorkspaceAppAutomationState> { automation in
                automation.appID == appID
            },
            sortBy: [SortDescriptor(\.automationID)]
        )
        return try modelContext.fetch(descriptor)
    }

    @MainActor
    func setAutomationEnabled(
        app: WorkspaceApp,
        automationID: String,
        isEnabled: Bool,
        workspace: Workspace?,
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        let states = try automationStates(for: app, modelContext: modelContext)
        guard let automation = states.first(where: { $0.automationID == automationID }) else {
            throw WorkspaceAppServiceError.missingAutomation(automationID)
        }

        automation.isEnabled = isEnabled
        automation.status = isEnabled ? .enabled : .disabled
        if isEnabled {
            automation.nextRunAt = automationSpec(app: app, automationID: automationID, workspace: workspace)
                .flatMap { automationScheduler.nextRunDate(for: $0, after: now) }
        } else {
            automation.nextRunAt = nil
        }
        automation.updatedAt = now
        app.updatedAt = now
        workspace?.updatedAt = now
        try modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.workspaceStoreMigrated, category: "WorkspaceApps", fields: [
            "resource": "workspace_app_automation_state",
            "result": isEnabled ? "enabled" : "disabled",
            "app_id": app.logicalID,
            "automation_id": automationID,
            "workspace_id": workspace?.id.uuidString ?? app.workspaceID.uuidString
        ])
    }

    private func automationSpec(
        app: WorkspaceApp,
        automationID: String,
        workspace: Workspace?
    ) -> WorkspaceAppAutomationSpec? {
        guard let workspace else { return nil }
        guard let manifest = try? WorkspaceAppManifestStore(fileManager: fileManager)
            .loadManifest(app: app, workspace: workspace).manifest else {
            return nil
        }
        return manifest.automations.first { $0.id == automationID }
    }

    @MainActor
    private func existingLogicalIDs(
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Set<String> {
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceApp>(
            predicate: #Predicate<WorkspaceApp> { app in
                app.workspaceID == workspaceID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.logicalID))
    }

    @MainActor
    private func existingNames(
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Set<String> {
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceApp>(
            predicate: #Predicate<WorkspaceApp> { app in
                app.workspaceID == workspaceID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.name))
    }

    private func uniqueLogicalID(base: String, existingLogicalIDs: Set<String>) -> String {
        guard existingLogicalIDs.contains(base) else { return base }
        var suffix = 2
        while existingLogicalIDs.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private func uniqueDisplayName(base: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(base) else { return base }
        var suffix = 2
        while existingNames.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    nonisolated static func encodeManifest(_ manifest: WorkspaceAppManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    nonisolated static func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
