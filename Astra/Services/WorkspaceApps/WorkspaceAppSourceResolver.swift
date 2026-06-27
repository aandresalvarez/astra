import Foundation

enum WorkspaceAppSourceResolutionError: LocalizedError, Equatable {
    case missingSource(String)
    case missingStorageTable(String)
    case missingRequirement(String)
    case missingMappedBinding(String)
    case unsupportedSource(String)
    case capabilityReadUnavailable(String)
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let sourceID):
            "Workspace app source '\(sourceID)' was not found."
        case .missingStorageTable(let table):
            "Workspace app source references unknown storage table '\(table)'."
        case .missingRequirement(let requirementID):
            "Workspace app source references unknown requirement '\(requirementID)'."
        case .missingMappedBinding(let requirementID):
            "Workspace app source requirement '\(requirementID)' is not mapped to a capability implementation."
        case .unsupportedSource(let sourceID):
            "Workspace app source '\(sourceID)' is not supported by the deterministic resolver."
        case .capabilityReadUnavailable(let sourceID):
            "Workspace app source '\(sourceID)' does not have a capability read implementation."
        case .storageFailed(let message):
            "Workspace app source storage read failed: \(message)"
        }
    }
}

struct WorkspaceAppSourceResolutionInput: Codable, Sendable, Equatable {
    var limit: Int
    var parameters: [String: WorkspaceAppStorageValue]

    init(limit: Int = 100, parameters: [String: WorkspaceAppStorageValue] = [:]) {
        self.limit = limit
        self.parameters = parameters
    }
}

struct WorkspaceAppResolvedSource: Sendable, Equatable {
    var sourceID: String
    var rows: [[String: WorkspaceAppStorageValue]]
    var outputSummary: String
    var requirementID: String?
    var implementationID: String?
    var provider: String?
}

protocol WorkspaceAppCapabilitySourceClient {
    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]]
}

protocol WorkspaceAppAsyncCapabilitySourceClient {
    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]]
}

struct WorkspaceAppUnavailableCapabilitySourceClient: WorkspaceAppCapabilitySourceClient {
    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
    }
}

struct WorkspaceAppUnavailableAsyncCapabilitySourceClient: WorkspaceAppAsyncCapabilitySourceClient {
    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
    }
}

struct WorkspaceAppSourceResolver {
    var storageService = WorkspaceAppStorageService()
    var capabilityClient: any WorkspaceAppCapabilitySourceClient = WorkspaceAppUnavailableCapabilitySourceClient()
    var asyncCapabilityClient: any WorkspaceAppAsyncCapabilitySourceClient = WorkspaceAppNativeAsyncCapabilitySourceClient()
    /// Runs a capability-contributed GENERIC read (a `.cli` `readExecution` spec) — no per-provider Swift.
    var genericCLIReadClient = WorkspaceAppGenericCLIReadClient()
    /// Implementations contributed by the workspace's ENABLED capabilities. Default derives them from the
    /// capability library; tests inject a fixed list so the suite never touches the filesystem.
    var capabilityImplementations: (Workspace) -> [WorkspaceAppContractImplementation] = { workspace in
        WorkspaceAppCapabilityContractDeriver.derived(for: workspace).implementations
    }

    func resolve(
        sourceID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppSourceResolutionInput = WorkspaceAppSourceResolutionInput()
    ) throws -> WorkspaceAppResolvedSource {
        guard let source = manifest.sources.first(where: { $0.id == sourceID }) else {
            throw WorkspaceAppSourceResolutionError.missingSource(sourceID)
        }
        if let table = storageTable(for: source, manifest: manifest) {
            return try resolveStorageSource(
                source,
                table: table,
                app: app,
                workspace: workspace,
                input: input
            )
        }
        guard let requirementID = source.requirementRef else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return try resolveCapabilitySource(
            source,
            requirementID: requirementID,
            app: app,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input
        )
    }

    func resolveAsync(
        sourceID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppSourceResolutionInput = WorkspaceAppSourceResolutionInput()
    ) async throws -> WorkspaceAppResolvedSource {
        guard let source = manifest.sources.first(where: { $0.id == sourceID }) else {
            throw WorkspaceAppSourceResolutionError.missingSource(sourceID)
        }
        if let table = storageTable(for: source, manifest: manifest) {
            return try resolveStorageSource(
                source,
                table: table,
                app: app,
                workspace: workspace,
                input: input
            )
        }
        guard let requirementID = source.requirementRef else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return try await resolveCapabilitySourceAsync(
            source,
            requirementID: requirementID,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input
        )
    }

    /// Connector-only SYNC resolution for a `capability.read` action (native button OR a pipeline/loop
    /// step run through `astra.runAction`). Like its async sibling, it NEVER falls through to app storage:
    /// a `capability.read` is a connector read by definition, so a source whose id/tableRef shadows a
    /// storage table must still resolve through its dependency binding, not the app's SQLite. Requires a
    /// connector requirement (`requirementRef`); throws `unsupportedSource` otherwise.
    func resolveCapabilityRead(
        sourceID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppSourceResolutionInput = WorkspaceAppSourceResolutionInput()
    ) throws -> WorkspaceAppResolvedSource {
        guard let source = manifest.sources.first(where: { $0.id == sourceID }) else {
            throw WorkspaceAppSourceResolutionError.missingSource(sourceID)
        }
        guard let requirementID = source.requirementRef else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return try resolveCapabilitySource(
            source,
            requirementID: requirementID,
            app: app,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input
        )
    }

    /// Connector-only async resolution for `capability.read` (the `astra.read` bridge path). Unlike
    /// `resolveAsync`, it NEVER falls through to app storage: a `capability.read` source whose id /
    /// tableRef / sourceRef happens to match a storage table must STILL resolve through its dependency
    /// binding (the connector authority), not silently read the app's own SQLite. Requires a connector
    /// requirement (`requirementRef`); throws `unsupportedSource` otherwise. This is the resolver-side
    /// half of the storage-shadow defense (the bridge's `resolveRead` requirementRef check is the other).
    func resolveCapabilityReadAsync(
        sourceID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppSourceResolutionInput = WorkspaceAppSourceResolutionInput()
    ) async throws -> WorkspaceAppResolvedSource {
        guard let source = manifest.sources.first(where: { $0.id == sourceID }) else {
            throw WorkspaceAppSourceResolutionError.missingSource(sourceID)
        }
        guard let requirementID = source.requirementRef else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return try await resolveCapabilitySourceAsync(
            source,
            requirementID: requirementID,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input
        )
    }

    private func storageTable(
        for source: WorkspaceAppSource,
        manifest: WorkspaceAppManifest
    ) -> String? {
        let candidates = [source.tableRef, source.sourceRef, source.id].compactMap { $0 }
        return candidates.first { candidate in
            manifest.storage?.tables.contains { $0.name == candidate } == true
        }
    }

    private func resolveStorageSource(
        _ source: WorkspaceAppSource,
        table: String,
        app: WorkspaceApp,
        workspace: Workspace,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> WorkspaceAppResolvedSource {
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        do {
            let rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
            return WorkspaceAppResolvedSource(
                sourceID: source.id,
                rows: rows,
                outputSummary: "Resolved source '\(source.id)' from app storage table '\(table)' with \(rows.count) rows.",
                requirementID: source.requirementRef,
                implementationID: "app-storage-native",
                provider: "astra"
            )
        } catch {
            throw WorkspaceAppSourceResolutionError.storageFailed(String(describing: error))
        }
    }

    private func resolveCapabilitySource(
        _ source: WorkspaceAppSource,
        requirementID: String,
        app: WorkspaceApp,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppSourceResolutionInput
    ) throws -> WorkspaceAppResolvedSource {
        guard let requirement = manifest.requirements.first(where: { $0.id == requirementID }) else {
            throw WorkspaceAppSourceResolutionError.missingRequirement(requirementID)
        }
        guard let binding = dependencyBindings.first(where: {
            $0.appID == app.id && $0.requirementID == requirementID && $0.status == .mapped
        }) else {
            throw WorkspaceAppSourceResolutionError.missingMappedBinding(requirementID)
        }
        let rows = try capabilityClient.read(
            source: source,
            requirement: requirement,
            binding: binding,
            input: input
        )
        return WorkspaceAppResolvedSource(
            sourceID: source.id,
            rows: rows,
            outputSummary: "Resolved source '\(source.id)' through \(binding.contract) using \(binding.implementationID ?? "unmapped") with \(rows.count) rows.",
            requirementID: requirementID,
            implementationID: binding.implementationID,
            provider: binding.provider
        )
    }

    private func resolveCapabilitySourceAsync(
        _ source: WorkspaceAppSource,
        requirementID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> WorkspaceAppResolvedSource {
        guard let requirement = manifest.requirements.first(where: { $0.id == requirementID }) else {
            throw WorkspaceAppSourceResolutionError.missingRequirement(requirementID)
        }
        guard let binding = dependencyBindings.first(where: {
            $0.appID == app.id && $0.requirementID == requirementID && $0.status == .mapped
        }) else {
            throw WorkspaceAppSourceResolutionError.missingMappedBinding(requirementID)
        }
        // If the mapped implementation is one an ENABLED capability contributed (it carries a generic
        // `readExecution` spec), run it through the generic client — NO per-provider Swift. Otherwise use
        // the built-in native client (BigQuery/REDCap/GitHub). The binding is still the appID-scoped,
        // `.mapped` authority; this only chooses HOW to execute, never WHETHER.
        if let implementationID = binding.implementationID,
           let implementation = capabilityImplementations(workspace).first(where: { $0.id == implementationID }),
           let execution = implementation.readExecution {
            let operation = source.operation ?? requirement.operations.first ?? WorkspaceAppCapabilityContractDeriver.defaultOperation
            let rows = try await genericCLIReadClient.read(
                execution: execution, operation: operation, sourceID: source.id,
                workspacePath: workspace.primaryPath, input: input
            )
            return WorkspaceAppResolvedSource(
                sourceID: source.id,
                rows: rows,
                outputSummary: "Resolved source '\(source.id)' through \(binding.contract) using \(implementationID) (generic \(execution.transport.rawValue)) with \(rows.count) rows.",
                requirementID: requirementID,
                implementationID: implementationID,
                provider: binding.provider
            )
        }
        let rows = try await asyncCapabilityClient.read(
            source: source,
            requirement: requirement,
            binding: binding,
            input: input
        )
        return WorkspaceAppResolvedSource(
            sourceID: source.id,
            rows: rows,
            outputSummary: "Resolved source '\(source.id)' through \(binding.contract) using \(binding.implementationID ?? "unmapped") with \(rows.count) rows.",
            requirementID: requirementID,
            implementationID: binding.implementationID,
            provider: binding.provider
        )
    }
}
