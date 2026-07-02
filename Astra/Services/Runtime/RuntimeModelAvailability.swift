import Foundation
import ASTRACore

enum RuntimeModelAvailabilityAuthority: String, Codable, Equatable, Sendable {
    case authoritative
    case suggestions
}

/// Optional human-facing metadata for one model ID, as reported by the
/// provider (e.g. the Claude CLI initialize handshake). `value` is the
/// string passed to `--model`; the rest is display-only.
struct RuntimeModelDetail: Codable, Equatable, Sendable {
    var value: String
    var displayName: String?
    var description: String?

    init(value: String, displayName: String? = nil, description: String? = nil) {
        self.value = value
        self.displayName = displayName
        self.description = description
    }
}

struct RuntimeModelAvailabilitySnapshot: Codable, Equatable, Sendable {
    var runtimeID: String
    var models: [String]
    var checkedAt: Date
    var authority: RuntimeModelAvailabilityAuthority
    var hasExplicitAuthority: Bool
    /// Optional display metadata for entries in `models`, matched by
    /// `value`. `models` stays the canonical list; absent in snapshots
    /// written before this field existed.
    var details: [RuntimeModelDetail]?

    init(
        runtimeID: String,
        models: [String],
        checkedAt: Date,
        authority: RuntimeModelAvailabilityAuthority = .authoritative,
        details: [RuntimeModelDetail]? = nil
    ) {
        self.runtimeID = runtimeID
        self.models = models
        self.checkedAt = checkedAt
        self.authority = authority
        self.hasExplicitAuthority = true
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeID
        case models
        case checkedAt
        case authority
        case details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeID = try container.decode(String.self, forKey: .runtimeID)
        models = try container.decode([String].self, forKey: .models)
        checkedAt = try container.decode(Date.self, forKey: .checkedAt)
        hasExplicitAuthority = container.contains(.authority)
        authority = try container.decodeIfPresent(
            RuntimeModelAvailabilityAuthority.self,
            forKey: .authority
        ) ?? .authoritative
        details = try container.decodeIfPresent([RuntimeModelDetail].self, forKey: .details)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeID, forKey: .runtimeID)
        try container.encode(models, forKey: .models)
        try container.encode(checkedAt, forKey: .checkedAt)
        try container.encode(authority, forKey: .authority)
        try container.encodeIfPresent(details, forKey: .details)
    }
}

struct RuntimeModelAvailabilityCache: Equatable, Sendable {
    private var rawSnapshots: [AgentRuntimeID: String]

    init(rawSnapshots: [AgentRuntimeID: String] = [:]) {
        self.rawSnapshots = rawSnapshots
    }

    init(cachedClaudeModelsJSON: String, cachedCopilotModelsJSON: String) {
        self.init(rawSnapshots: [
            .claudeCode: cachedClaudeModelsJSON,
            .copilotCLI: cachedCopilotModelsJSON
        ])
    }

    static func appStorage(
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        defaults: UserDefaults = .standard,
        runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs
    ) -> RuntimeModelAvailabilityCache {
        var snapshots: [AgentRuntimeID: String] = [
            .claudeCode: cachedClaudeModelsJSON,
            .copilotCLI: cachedCopilotModelsJSON
        ]
        for runtime in runtimes where snapshots[runtime] == nil {
            snapshots[runtime] = defaults.string(forKey: AppStorageKeys.runtimeAvailableModelsKey(for: runtime)) ?? ""
        }
        return RuntimeModelAvailabilityCache(rawSnapshots: snapshots)
    }

    func rawSnapshot(for runtime: AgentRuntimeID) -> String {
        rawSnapshots[runtime] ?? ""
    }

    mutating func setRawSnapshot(_ raw: String, for runtime: AgentRuntimeID) {
        rawSnapshots[runtime] = raw
    }
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

    func diagnosticFields(phase: RunPhase) -> [String: String] {
        var fields: [String: String] = [
            "runtime": runtime.rawValue,
            "phase": phase.rawValue,
            "requested_model": requestedModel.isEmpty ? "empty" : requestedModel,
            "resolved_model": resolvedModel,
            "model_changed": String(changed),
            "selection_source": source,
            "selection_reason": reason,
            "available_model_count": String(availableModelCount),
            "runtime_default_model": AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
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
        cachedModels(for: runtime, defaults: defaults) ?? AgentRuntimeAdapterRegistry.defaultModels(for: runtime)
    }

    static func models(
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> [String] {
        cachedModels(for: runtime, cache: cache) ?? AgentRuntimeAdapterRegistry.defaultModels(for: runtime)
    }

    static func models(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> [String] {
        models(
            for: runtime,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
    }

    static func defaultModel(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> String {
        defaultSuggestion(for: runtime, suggestions: models(for: runtime, defaults: defaults))
    }

    static func defaultModel(
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> String {
        defaultSuggestion(for: runtime, suggestions: models(for: runtime, cache: cache))
    }

    static func defaultModel(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        defaultModel(
            for: runtime,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
    }

    /// Human-facing name for a model in this runtime's picker: the
    /// provider-reported display name when the cache has one, otherwise
    /// the generic string prettifier.
    static func displayName(
        for model: String,
        runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> String {
        cachedDetail(for: model, runtime: runtime, cache: cache)?.displayName
            ?? RuntimeModelDisplayName.displayName(model)
    }

    /// Provider-reported description for a model, when the cache has one.
    static func modelDescription(
        for model: String,
        runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> String? {
        cachedDetail(for: model, runtime: runtime, cache: cache)?.description
    }

    private static func cachedDetail(
        for model: String,
        runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> RuntimeModelDetail? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return cachedSnapshot(for: runtime, cache: cache)?
            .details?
            .first { $0.value == trimmed }
    }

    static func hasCachedModels(
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> Bool {
        cachedModels(for: runtime, cache: cache) != nil
    }

    static func hasCachedModels(
        for runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> Bool {
        hasCachedModels(
            for: runtime,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
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
        cache: RuntimeModelAvailabilityCache
    ) -> String {
        resolveModel(model, for: runtime, cache: cache).resolvedModel
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
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
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
            return (AgentRuntimeAdapterRegistry.defaultModels(for: runtime).count, nil)
        }
        return (snapshot.models.count, snapshot.checkedAt)
    }

    static func modelForRuntimeSwitch(
        currentModel: String,
        to runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> String {
        let trimmed = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = models(for: runtime, cache: cache)
        if suggestions.contains(trimmed) {
            return trimmed
        }
        let runtimeDefaultModel = AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
        if suggestions.contains(runtimeDefaultModel) {
            return runtimeDefaultModel
        }
        return suggestions.first ?? runtimeDefaultModel
    }

    static func modelForRuntimeSwitch(
        currentModel: String,
        to runtime: AgentRuntimeID,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String
    ) -> String {
        modelForRuntimeSwitch(
            currentModel: currentModel,
            to: runtime,
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON
            )
        )
    }

    static func resolveModel(
        _ model: String,
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> RuntimeModelResolution {
        resolveModel(
            model,
            for: runtime,
            cachedSnapshot: cachedSnapshot(for: runtime, cache: cache)
        )
    }

    static func persistAvailableModels(
        _ models: [String],
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard,
        checkedAt: Date = Date(),
        authority: RuntimeModelAvailabilityAuthority = .authoritative
    ) {
        persistAvailableModelDetails(
            models.map { RuntimeModelDetail(value: $0) },
            for: runtime,
            defaults: defaults,
            checkedAt: checkedAt,
            authority: authority
        )
    }

    @MainActor
    static func persistObservedAvailableModels(
        _ models: [String],
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard,
        checkedAt: Date = Date(),
        authority: RuntimeModelAvailabilityAuthority = .authoritative
    ) {
        persistAvailableModels(
            models,
            for: runtime,
            defaults: defaults,
            checkedAt: checkedAt,
            authority: authority
        )
    }

    static func persistAvailableModelDetails(
        _ details: [RuntimeModelDetail],
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard,
        checkedAt: Date = Date(),
        authority: RuntimeModelAvailabilityAuthority = .authoritative
    ) {
        let cleaned = cleanProviderModelDetails(details)
        guard !cleaned.isEmpty else { return }
        let hasMetadata = cleaned.contains { $0.displayName != nil || $0.description != nil }
        let snapshot = RuntimeModelAvailabilitySnapshot(
            runtimeID: runtime.rawValue,
            models: cleaned.map(\.value),
            checkedAt: checkedAt,
            authority: authority,
            details: hasMetadata ? cleaned : nil
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: availableModelsKey(for: runtime))
        defaults.set(checkedAt.timeIntervalSince1970, forKey: checkedAtKey(for: runtime))
        bumpCacheRevision(defaults: defaults)
    }

    @MainActor
    static func persistObservedAvailableModelDetails(
        _ details: [RuntimeModelDetail],
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard,
        checkedAt: Date = Date(),
        authority: RuntimeModelAvailabilityAuthority = .authoritative
    ) {
        persistAvailableModelDetails(
            details,
            for: runtime,
            defaults: defaults,
            checkedAt: checkedAt,
            authority: authority
        )
    }

    static func clearAvailableModels(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: availableModelsKey(for: runtime))
        defaults.removeObject(forKey: checkedAtKey(for: runtime))
        bumpCacheRevision(defaults: defaults)
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
        let authority = snapshot.hasExplicitAuthority
            ? snapshot.authority
            : legacySnapshotAuthority(for: runtime)
        return RuntimeModelAvailabilitySnapshot(
            runtimeID: snapshot.runtimeID,
            models: cleaned,
            checkedAt: snapshot.checkedAt,
            authority: authority,
            details: snapshot.details.map(cleanProviderModelDetails)
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

    /// Same dedupe/trim rules as `cleanProviderModels`, applied to the
    /// `value` field; the first occurrence keeps its metadata. Blank
    /// display strings collapse to nil.
    static func cleanProviderModelDetails(_ details: [RuntimeModelDetail]) -> [RuntimeModelDetail] {
        var seen: Set<String> = []
        var cleaned: [RuntimeModelDetail] = []
        for detail in details {
            let value = detail.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            cleaned.append(RuntimeModelDetail(
                value: value,
                displayName: normalizedDisplayString(detail.displayName),
                description: normalizedDisplayString(detail.description)
            ))
        }
        return cleaned
    }

    private static func normalizedDisplayString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cachedModels(for runtime: AgentRuntimeID, defaults: UserDefaults) -> [String]? {
        cachedSnapshot(for: runtime, defaults: defaults)?.models
    }

    private static func cachedSnapshot(for runtime: AgentRuntimeID, defaults: UserDefaults) -> RuntimeModelAvailabilitySnapshot? {
        cachedSnapshot(from: defaults.string(forKey: availableModelsKey(for: runtime)) ?? "", for: runtime)
    }

    private static func cachedModels(
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> [String]? {
        cachedSnapshot(for: runtime, cache: cache)?.models
    }

    private static func cachedSnapshot(
        for runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) -> RuntimeModelAvailabilitySnapshot? {
        cachedSnapshot(from: cache.rawSnapshot(for: runtime), for: runtime)
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
        let suggestions = cachedSnapshot?.models ?? AgentRuntimeAdapterRegistry.defaultModels(for: runtime)
        let source = cachedSnapshot == nil ? "built_in_defaults" : "cached_provider_models"
        let checkedAt = cachedSnapshot?.checkedAt
        let cachedListIsAuthoritative = cachedSnapshot?.authority == .authoritative
        let unavailableModelFallback = fallbackSuggestion(
            for: runtime,
            suggestions: suggestions,
            authority: cachedSnapshot?.authority
        )
        guard !suggestions.isEmpty else {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
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
        if trimmed.lowercased() == "default" {
            return RuntimeModelResolution(
                runtime: runtime,
                requestedModel: trimmed,
                resolvedModel: defaultSuggestion(for: runtime, suggestions: suggestions),
                source: source,
                reason: "legacy_default_alias",
                availableModelCount: suggestions.count,
                checkedAt: checkedAt
            )
        }
        if cachedListIsAuthoritative {
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
                resolvedModel: unavailableModelFallback,
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
        let runtimeDefaultModel = AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
        if suggestions.contains(runtimeDefaultModel) {
            return runtimeDefaultModel
        }
        return suggestions.first ?? runtimeDefaultModel
    }

    private static func fallbackSuggestion(
        for runtime: AgentRuntimeID,
        suggestions: [String],
        authority: RuntimeModelAvailabilityAuthority?
    ) -> String {
        if authority == .suggestions {
            return suggestions.first ?? AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
        }
        return defaultSuggestion(for: runtime, suggestions: suggestions)
    }

    private static func isKnownModel(_ model: String, outside runtime: AgentRuntimeID) -> Bool {
        AgentRuntimeAdapterRegistry.descriptors.contains { descriptor in
            descriptor.id != runtime && descriptor.defaultModels.contains(model)
        }
    }

    private static func availableModelsKey(for runtime: AgentRuntimeID) -> String {
        AgentRuntimeAdapterRegistry.adapterIfRegistered(for: runtime)?.availableModelsStorageKey
            ?? AppStorageKeys.runtimeAvailableModelsKey(for: runtime)
    }

    private static func checkedAtKey(for runtime: AgentRuntimeID) -> String {
        AgentRuntimeAdapterRegistry.adapterIfRegistered(for: runtime)?.modelsCheckedAtStorageKey
            ?? AppStorageKeys.runtimeModelsCheckedAtKey(for: runtime)
    }

    private static func legacySnapshotAuthority(for runtime: AgentRuntimeID) -> RuntimeModelAvailabilityAuthority {
        AgentRuntimeAdapterRegistry.adapterIfRegistered(for: runtime)?.modelAvailabilityAuthority ?? .authoritative
    }

    private static func bumpCacheRevision(defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: AppStorageKeys.runtimeModelCacheRevision) + 1,
                     forKey: AppStorageKeys.runtimeModelCacheRevision)
    }
}
