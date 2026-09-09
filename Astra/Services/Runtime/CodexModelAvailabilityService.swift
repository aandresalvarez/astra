import Foundation
import ASTRACore

struct CodexModelInfo: Codable, Equatable, Sendable {
    struct ReasoningEffort: Codable, Equatable, Sendable {
        var reasoningEffort: String
        var description: String
    }

    var model: String
    var displayName: String?
    var description: String?
    var hidden: Bool?
    var isDefault: Bool?
    var defaultReasoningEffort: String?
    var supportedReasoningEfforts: [ReasoningEffort]?
    var inputModalities: [String]?
}

protocol CodexModelCatalogProbing: Sendable {
    func models(executablePath: String, environment: [String: String]) async throws -> [CodexModelInfo]
}

enum CodexModelAvailabilityResult: Equatable, Sendable {
    case available(models: [RuntimeModelDetail])
    case unavailable(reason: String)
}

struct CodexModelAvailabilityService {
    var probe: any CodexModelCatalogProbing = CodexAppServerModelProbe()
    var detectExecutable: @Sendable () -> String = { CodexCLIRuntime.detectPath() }

    func refreshAndPersist(
        executablePath: String,
        homeDirectory: String = "",
        defaults: UserDefaults = .standard
    ) async -> CodexModelAvailabilityResult {
        let configured = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configured.isEmpty ? detectExecutable() : configured
        var environment = RuntimeProcessEnvironment.enriched()
        let home = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty { environment["CODEX_HOME"] = home }
        do {
            let catalog = try await probe.models(executablePath: executable, environment: environment)
            try Task.checkCancellation()
            let visible = catalog.filter { $0.hidden != true }
            // Preserve provider order within each group; the recommended default
            // leads the existing cache so all default-model consumers agree.
            let ordered = visible.filter { $0.isDefault == true } + visible.filter { $0.isDefault != true }
            let details = RuntimeModelAvailability.cleanProviderModelDetails(ordered.map {
                RuntimeModelDetail(value: $0.model, displayName: $0.displayName, description: $0.description, codex: $0)
            })
            guard !details.isEmpty else { throw CodexModelProbeError.emptyCatalog }
            // A picker catalog is not an execution allowlist: hidden and custom
            // models can still be explicitly selected by existing tasks.
            await RuntimeModelAvailability.persistObservedAvailableModelDetails(
                details, for: .codexCLI, defaults: defaults, authority: .suggestions
            )
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.codexCLI.rawValue,
                "result": "available", "model_count": String(details.count)
            ], level: .debug)
            return .available(models: details)
        } catch {
            let reason = (error as? CodexModelProbeError)?.localizedDescription
                ?? (error is CancellationError ? "Codex model discovery was cancelled." : "Could not load the Codex model catalog.")
            AppLogger.audit(.runtimeModelAvailability, category: "Worker", fields: [
                "runtime": AgentRuntimeID.codexCLI.rawValue,
                "result": "unavailable", "reason": reason
            ], level: .warning)
            return .unavailable(reason: reason)
        }
    }
}

enum CodexModelProbeError: Error, LocalizedError, Equatable {
    case unavailableExecutable, timedOut, exited, invalidResponse, rpcError, repeatedCursor, emptyCatalog, outputLimit

    var errorDescription: String? {
        switch self {
        case .unavailableExecutable: "No runnable Codex CLI was found for model discovery."
        case .timedOut: "Codex model discovery timed out."
        case .exited: "Codex app-server exited before completing model discovery."
        case .invalidResponse: "Codex returned an invalid model discovery response."
        case .rpcError: "Codex rejected model discovery. Check the configured CLI version and login."
        case .repeatedCursor: "Codex model discovery returned a repeated pagination cursor."
        case .emptyCatalog: "Codex returned no picker-visible models."
        case .outputLimit: "Codex model discovery exceeded its response limit."
        }
    }
}
