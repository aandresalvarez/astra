import Foundation
import ASTRAModels

struct WorkspaceAppCapabilityReadRequest {
    var action: WorkspaceAppActionSpec
    var app: WorkspaceApp
    var workspace: Workspace
    var manifest: WorkspaceAppManifest
    var dependencyBindings: [WorkspaceAppDependencyBinding]
    var input: WorkspaceAppActionInput
    var surface: WorkspaceAppBridgeSurface

    init(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        surface: WorkspaceAppBridgeSurface
    ) {
        self.action = action
        self.app = app
        self.workspace = workspace
        self.manifest = manifest
        self.dependencyBindings = dependencyBindings
        self.input = input
        self.surface = surface
    }
}

struct WorkspaceAppCapabilityReadPipeline {
    var sourceResolver: WorkspaceAppSourceResolver
    var readPolicy: WorkspaceAppReadPolicy

    init(
        sourceResolver: WorkspaceAppSourceResolver = WorkspaceAppSourceResolver(),
        readPolicy: WorkspaceAppReadPolicy = WorkspaceAppReadPolicy()
    ) {
        self.sourceResolver = sourceResolver
        self.readPolicy = readPolicy
    }

    func admit(_ request: WorkspaceAppCapabilityReadRequest) throws {
        try readPolicy.admitConnectorRead(
            actionID: request.action.id,
            appID: request.app.id,
            surface: request.surface
        )
    }

    func resolve(_ request: WorkspaceAppCapabilityReadRequest) throws -> WorkspaceAppResolvedSource {
        try admit(request)
        return try resolveAdmitted(request)
    }

    func resolveAsync(_ request: WorkspaceAppCapabilityReadRequest) async throws -> WorkspaceAppResolvedSource {
        try admit(request)
        return try await resolveAdmittedAsync(request)
    }

    func resolveAdmitted(_ request: WorkspaceAppCapabilityReadRequest) throws -> WorkspaceAppResolvedSource {
        let sourceID = try Self.sourceID(for: request.action, input: request.input)
        return try sourceResolver.resolveCapabilityRead(
            sourceID: sourceID,
            app: request.app,
            workspace: request.workspace,
            manifest: request.manifest,
            dependencyBindings: request.dependencyBindings,
            input: WorkspaceAppSourceResolutionInput(
                limit: WorkspaceAppReadPolicy.connectorLimit(request.input.requestedLimit),
                parameters: request.input.record
            )
        )
    }

    func resolveAdmittedAsync(_ request: WorkspaceAppCapabilityReadRequest) async throws -> WorkspaceAppResolvedSource {
        let sourceID = try Self.sourceID(for: request.action, input: request.input)
        return try await sourceResolver.resolveCapabilityReadAsync(
            sourceID: sourceID,
            app: request.app,
            workspace: request.workspace,
            manifest: request.manifest,
            dependencyBindings: request.dependencyBindings,
            input: WorkspaceAppSourceResolutionInput(
                limit: WorkspaceAppReadPolicy.connectorLimit(request.input.requestedLimit),
                parameters: request.input.record
            )
        )
    }

    static func sourceID(
        for action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput
    ) throws -> String {
        let sourceID = [action.sourceRef, input.table, action.table]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !sourceID.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingSource
        }
        return sourceID
    }

    static func auditPayload(
        for resolved: WorkspaceAppResolvedSource,
        async: Bool = false
    ) -> [String: WorkspaceAppStorageValue] {
        var payload: [String: WorkspaceAppStorageValue] = [
            "sourceID": .text(resolved.sourceID),
            "rowCount": .integer(Int64(resolved.rows.count))
        ]
        if async {
            payload["async"] = .bool(true)
        }
        if let requirementID = resolved.requirementID {
            payload["requirementID"] = .text(requirementID)
        }
        if let implementationID = resolved.implementationID {
            payload["implementationID"] = .text(implementationID)
        }
        if let provider = resolved.provider {
            payload["provider"] = .text(provider)
        }
        return payload
    }
}
