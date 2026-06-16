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
