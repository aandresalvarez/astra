import Foundation
import ASTRACore

struct RuntimeModelAvailabilitySnapshot: Codable, Equatable, Sendable {
    var runtimeID: String
    var models: [String]
    var checkedAt: Date
}

struct RuntimeModelResolution: Equatable, Sendable {
    let runtime: AgentRuntimeID
    let requestedModel: String
    let resolvedModel: String
    let source: String
    let reason: String
    let availableModelCount: Int
    let checkedAt: Date?

    var changed: Bool {
        requestedModel != resolvedModel
    }

    func diagnosticFields(phase: String) -> [String: String] {
        var fields: [String: String] = [
            "runtime": runtime.rawValue,
            "phase": phase,
            "requested_model": requestedModel.isEmpty ? "empty" : requestedModel,
            "resolved_model": resolvedModel,
            "model_changed": String(changed),
            "selection_source": source,
            "selection_reason": reason,
            "available_model_count": String(availableModelCount),
            "runtime_default_model": runtime.defaultModel
        ]
        if let checkedAt {
            fields["availability_checked_at"] = String(Int(checkedAt.timeIntervalSince1970))
        } else {
            fields["availability_checked_at"] = "none"
        }
        return fields
    }
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

    static func hasCachedModels(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> Bool {
        cachedModels(
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        ) != nil
    }

    static func normalizedModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) -> String {
        resolveModel(
            model,
            for: runtime,
            cachedSnapshot: cachedSnapshot(for: runtime, defaults: defaults)
        ).resolvedModel
    }

    static func normalizedModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        resolveModel(
            model,
            for: runtime,
            cachedSnapshot: cachedSnapshot(
                for: runtime,
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        ).resolvedModel
    }

    static func resolveModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) -> RuntimeModelResolution {
        resolveModel(
            model,
            for: runtime,
            cachedSnapshot: cachedSnapshot(for: runtime, defaults: defaults)
        )
    }

    static func cacheSummary(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> (count: Int, checkedAt: Date?) {
        guard let snapshot = cachedSnapshot(for: runtime, defaults: defaults) else {
            return (runtime.defaultModels.count, nil)
        }
        return (snapshot.models.count, snapshot.checkedAt)
    }

    static func modelForRuntimeSwitch(
        currentModel: String,
        to runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        let trimmed = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = models(
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        )
        if suggestions.contains(trimmed) {
            return trimmed
        }
        if suggestions.contains(runtime.defaultModel) {
            return runtime.defaultModel
        }
        return suggestions.first ?? runtime.defaultModel
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
        cachedSnapshot(from: raw, for: runtime)?.models
    }

    private static func cachedSnapshot(from raw: String, for runtime: AgentRuntimeID) -> RuntimeModelAvailabilitySnapshot? {
        guard let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(RuntimeModelAvailabilitySnapshot.self, from: data),
              snapshot.runtimeID == runtime.rawValue else {
            return nil
        }
        let cleaned = cleanProviderModels(snapshot.models)
        guard !cleaned.isEmpty else { return nil }
        return RuntimeModelAvailabilitySnapshot(
            runtimeID: snapshot.runtimeID,
            models: cleaned,
            checkedAt: snapshot.checkedAt
        )
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
        cachedSnapshot(for: runtime, defaults: defaults)?.models
    }

    private static func cachedSnapshot(for runtime: AgentRuntimeID, defaults: UserDefaults) -> RuntimeModelAvailabilitySnapshot? {
        cachedSnapshot(from: defaults.string(forKey: availableModelsKey(for: runtime)) ?? "", for: runtime)
    }

    private static func cachedModels(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> [String]? {
        cachedSnapshot(
            for: runtime,
            cachedClaudeModelsJSON: cachedClaudeModelsJSON,
            cachedCopilotModelsJSON: cachedCopilotModelsJSON
        )?.models
    }

    private static func cachedSnapshot(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> RuntimeModelAvailabilitySnapshot? {
        let raw = AgentRuntimeAdapterRegistry
            .adapter(for: runtime)
            .cachedModelsJSON(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        return cachedSnapshot(from: raw, for: runtime)
    }

    private static func resolveModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        cachedSnapshot: RuntimeModelAvailabilitySnapshot?
    ) -> RuntimeModelResolution {
        // Model IDs are scoped to the selected runtime. Unknown custom IDs are
        // preserved so future provider models can be typed manually, but a
        // model known to belong to a different runtime must not bleed across
        // providers. If the selected runtime has a cached account/CLI model
        // list, that provider-specific list becomes authoritative.
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = cachedSnapshot?.models ?? runtime.defaultModels
        let source = cachedSnapshot == nil ? "built_in_defaults" : "cached_provider_models"
        let checkedAt = cachedSnapshot?.checkedAt
        guard !suggestions.isEmpty else {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: runtime.defaultModel,
                source: source,
                reason: "empty_suggestion_list",
                availableModelCount: 0,
                checkedAt: checkedAt
            )
        }
        guard !trimmed.isEmpty else {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: defaultSuggestion(for: runtime, suggestions: suggestions),
                source: source,
                reason: "empty_requested_model",
                availableModelCount: suggestions.count,
                checkedAt: checkedAt
            )
        }
        if suggestions.contains(trimmed) {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: trimmed,
                source: source,
                reason: "available_for_runtime",
                availableModelCount: suggestions.count,
                checkedAt: checkedAt
            )
        }
        if cachedSnapshot != nil {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: defaultSuggestion(for: runtime, suggestions: suggestions),
                source: source,
                reason: "not_in_cached_provider_models",
                availableModelCount: suggestions.count,
                checkedAt: checkedAt
            )
        }
        if isKnownModel(trimmed, outside: runtime) {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: defaultSuggestion(for: runtime, suggestions: suggestions),
                source: source,
                reason: "known_other_runtime_model",
                availableModelCount: suggestions.count,
                checkedAt: checkedAt
            )
        }
        return RuntimeModelResolution(
            runtime: runtime,
            requestedModel: trimmed,
            resolvedModel: trimmed,
            source: source,
            reason: "unknown_custom_model_preserved",
            availableModelCount: suggestions.count,
            checkedAt: checkedAt
        )
    }

    private static func defaultSuggestion(for runtime: AgentRuntimeID, suggestions: [String]) -> String {
        if suggestions.contains(runtime.defaultModel) {
            return runtime.defaultModel
        }
        return suggestions.first ?? runtime.defaultModel
    }

    private static func isKnownModel(_ model: String, outside runtime: AgentRuntimeID) -> Bool {
        AgentRuntimeAdapterRegistry.descriptors.contains { descriptor in
            descriptor.id != runtime && descriptor.defaultModels.contains(model)
        }
    }

    private static func availableModelsKey(for runtime: AgentRuntimeID) -> String {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).availableModelsStorageKey
    }

    private static func checkedAtKey(for runtime: AgentRuntimeID) -> String {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).modelsCheckedAtStorageKey
    }
}
