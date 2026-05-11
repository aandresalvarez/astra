import Foundation
import ASTRACore

struct RuntimeModelAvailabilitySnapshot: Codable, Equatable, Sendable {
    var runtimeID: String
    var models: [String]
    var checkedAt: Date
}

enum RuntimeModelAvailability {
    static func models(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> [String] {
        cachedModels(for: runtime, defaults: defaults) ?? runtime.defaultModels
    }

    static func models(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> [String] {
        cachedModels(
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        ) ?? runtime.defaultModels
    }

    static func defaultModel(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> String {
        models(for: runtime, defaults: defaults).first ?? runtime.defaultModel
    }

    static func defaultModel(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        models(
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        ).first ?? runtime.defaultModel
    }

    static func normalizedModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) -> String {
        normalizedModel(
            model,
            for: runtime,
            cachedModels: cachedModels(for: runtime, defaults: defaults)
        )
    }

    static func normalizedModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        normalizedModel(
            model,
            for: runtime,
            cachedModels: cachedModels(
                for: runtime,
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
    }

    static func persistAvailableModels(
        _ models: [String],
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard,
        checkedAt: Date = Date()
    ) {
        let cleaned = cleanProviderModels(models)
        guard !cleaned.isEmpty else { return }
        let snapshot = RuntimeModelAvailabilitySnapshot(
            runtimeID: runtime.rawValue,
            models: cleaned,
            checkedAt: checkedAt
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: availableModelsKey(for: runtime))
        defaults.set(checkedAt.timeIntervalSince1970, forKey: checkedAtKey(for: runtime))
    }

    static func clearAvailableModels(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: availableModelsKey(for: runtime))
        defaults.removeObject(forKey: checkedAtKey(for: runtime))
    }

    static func cachedModels(from raw: String, for runtime: AgentRuntimeID) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(RuntimeModelAvailabilitySnapshot.self, from: data),
              snapshot.runtimeID == runtime.rawValue else {
            return nil
        }
        let cleaned = cleanProviderModels(snapshot.models)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func cleanProviderModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            cleaned.append(trimmed)
        }
        return cleaned
    }

    private static func cachedModels(for runtime: AgentRuntimeID, defaults: UserDefaults) -> [String]? {
        cachedModels(from: defaults.string(forKey: availableModelsKey(for: runtime)) ?? "", for: runtime)
    }

    private static func cachedModels(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> [String]? {
        switch runtime {
        case .claudeCode:
            cachedModels(from: cachedClaudeModelsJSON, for: runtime)
        case .copilotCLI:
            cachedModels(from: cachedCopilotModelsJSON, for: runtime)
        }
    }

    private static func normalizedModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        cachedModels: [String]?
    ) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedModels {
            guard !cachedModels.isEmpty else { return runtime.defaultModel }
            return cachedModels.contains(trimmed) ? trimmed : cachedModels[0]
        }
        guard !trimmed.isEmpty else { return runtime.defaultModel }
        if modelLooksLikeAnotherRuntimeDefault(trimmed, runtime: runtime) {
            return runtime.defaultModel
        }
        return trimmed
    }

    private static func modelLooksLikeAnotherRuntimeDefault(_ model: String, runtime: AgentRuntimeID) -> Bool {
        AgentRuntimeID.allCases
            .filter { $0 != runtime }
            .flatMap(\.defaultModels)
            .contains(model)
    }

    private static func availableModelsKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            AppStorageKeys.claudeAvailableModels
        case .copilotCLI:
            AppStorageKeys.copilotAvailableModels
        }
    }

    private static func checkedAtKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            AppStorageKeys.claudeModelsCheckedAt
        case .copilotCLI:
            AppStorageKeys.copilotModelsCheckedAt
        }
    }
}
