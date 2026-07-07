import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

enum TaskRoleProfileStore {
    @MainActor
    static func selection(
        for role: TaskRoleID,
        task: AgentTask? = nil,
        defaultRuntimeID: String? = nil,
        defaultModel: String? = nil,
        validationModel: String? = nil,
        defaultBudget: Int? = nil,
        defaultPolicyLevelRaw: String? = nil,
        providerSettings: AgentRuntimeProviderSettings = RuntimeProviderSettingsStore.settings(),
        cache: RuntimeModelAvailabilityCache = RuntimeModelAvailabilityCache(),
        defaults: UserDefaults = .standard
    ) -> TaskRoleProfileSelection {
        if role == .worker, let task {
            let runtime = task.resolvedRuntimeID
            let globalPolicyRaw = defaultPolicyLevelRaw
                ?? defaults.string(forKey: AppStorageKeys.defaultAgentPolicyLevel)
                ?? AgentPolicyLevel.review.rawValue
            return TaskRoleProfileSelection(
                profile: TaskRoleProfile(
                    role: role,
                    runtimeID: runtime.rawValue,
                    model: RuntimeModelAvailability.normalizedModel(task.model, for: runtime, cache: cache),
                    tokenBudget: task.tokenBudget,
                    policyLevelRaw: TaskPolicyStore.resolve(
                        for: task,
                        globalDefaultLevel: AgentPolicyLevel.normalized(globalPolicyRaw),
                        fallbackPermissionPolicy: .restricted,
                        executionPolicy: .default
                    ).level.rawValue
                ),
                source: "task_override"
            )
        }

        let fallbackRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: defaultRuntimeID ?? defaults.string(forKey: "defaultRuntimeID")
        )
        let fallbackModel = defaultModel ?? defaults.string(forKey: "defaultModel") ?? RuntimeModelAvailability.defaultModel(for: fallbackRuntime)
        let fallbackValidationModel = validationModel ?? defaults.string(forKey: "validationModel") ?? fallbackModel
        let fallbackBudget = defaultBudget ?? resolvedDefaultBudget(defaults: defaults)
        let fallbackPolicy = defaultPolicyLevelRaw
            ?? defaults.string(forKey: AppStorageKeys.defaultAgentPolicyLevel)
            ?? AgentPolicyLevel.review.rawValue

        let explicitRuntimeRaw = cleaned(defaults.string(forKey: AppStorageKeys.roleProfileRuntimeKey(for: role)))
        let explicitModel = cleaned(defaults.string(forKey: AppStorageKeys.roleProfileModelKey(for: role)))
        let explicitBudget = defaults.object(forKey: AppStorageKeys.roleProfileBudgetKey(for: role)) == nil
            ? nil
            : defaults.integer(forKey: AppStorageKeys.roleProfileBudgetKey(for: role))
        let explicitPolicy = cleaned(defaults.string(forKey: AppStorageKeys.roleProfilePolicyKey(for: role)))

        let runtime: AgentRuntimeID
        let source: String
        if let explicitRuntimeRaw {
            runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: explicitRuntimeRaw, fallback: fallbackRuntime)
            source = "role_profile"
        } else if role == .verifier,
                  let task,
                  let alternate = alternateVerifierRuntime(
                    workerRuntime: task.resolvedRuntimeID,
                    providerSettings: providerSettings
                  ) {
            runtime = alternate
            source = "default_independent"
        } else {
            runtime = fallbackRuntime
            source = "default"
        }

        let suggestedModel = switch role {
        case .planner, .worker:
            fallbackModel
        case .verifier, .browserTester, .summarizer:
            fallbackValidationModel
        }
        let model = RuntimeModelAvailability.normalizedModel(
            explicitModel ?? suggestedModel,
            for: runtime,
            cache: cache
        )
        let budget = max(0, explicitBudget ?? fallbackBudget)
        let policy = AgentPolicyLevel.normalized(explicitPolicy ?? fallbackPolicy).userFacingLevel.rawValue

        return TaskRoleProfileSelection(
            profile: TaskRoleProfile(
                role: role,
                runtimeID: runtime.rawValue,
                model: model,
                tokenBudget: budget,
                policyLevelRaw: policy
            ),
            source: source
        )
    }

    static func setProfile(
        _ profile: TaskRoleProfile,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(profile.runtimeID, forKey: AppStorageKeys.roleProfileRuntimeKey(for: profile.role))
        defaults.set(profile.model, forKey: AppStorageKeys.roleProfileModelKey(for: profile.role))
        defaults.set(profile.tokenBudget, forKey: AppStorageKeys.roleProfileBudgetKey(for: profile.role))
        defaults.set(profile.policyLevel.rawValue, forKey: AppStorageKeys.roleProfilePolicyKey(for: profile.role))
        bumpRevision(defaults: defaults)
        AppLogger.audit(.roleProfileChanged, category: "Settings", fields: auditFields(profile: profile, source: "settings"))
    }

    static func clearProfile(role: TaskRoleID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppStorageKeys.roleProfileRuntimeKey(for: role))
        defaults.removeObject(forKey: AppStorageKeys.roleProfileModelKey(for: role))
        defaults.removeObject(forKey: AppStorageKeys.roleProfileBudgetKey(for: role))
        defaults.removeObject(forKey: AppStorageKeys.roleProfilePolicyKey(for: role))
        bumpRevision(defaults: defaults)
    }

    @MainActor
    static func utilityRuntime(
        for role: TaskRoleID,
        task: AgentTask? = nil,
        defaultRuntimeID: String? = nil,
        defaultModel: String? = nil,
        validationModel: String? = nil,
        defaultBudget: Int? = nil,
        defaultPolicyLevelRaw: String? = nil,
        providerSettings: AgentRuntimeProviderSettings,
        cache: RuntimeModelAvailabilityCache = RuntimeModelAvailabilityCache(),
        defaults: UserDefaults = .standard
    ) -> (configuration: AgentUtilityRuntimeConfiguration, selection: TaskRoleProfileSelection) {
        let selection = selection(
            for: role,
            task: task,
            defaultRuntimeID: defaultRuntimeID,
            defaultModel: defaultModel,
            validationModel: validationModel,
            defaultBudget: defaultBudget,
            defaultPolicyLevelRaw: defaultPolicyLevelRaw,
            providerSettings: providerSettings,
            cache: cache,
            defaults: defaults
        )
        return (
            AgentUtilityRuntimeConfiguration(
                runtime: selection.profile.runtime,
                model: selection.profile.model,
                providerSettings: providerSettings
            ),
            selection
        )
    }

    @MainActor
    static func recordSelected(
        _ selection: TaskRoleProfileSelection,
        task: AgentTask,
        modelContext: ModelContext
    ) {
        let payload = TaskRoleProfileEventPayload(
            role: selection.profile.role,
            runtimeID: selection.profile.runtimeID,
            model: selection.profile.model,
            tokenBudget: selection.profile.tokenBudget,
            policyLevelRaw: selection.profile.policyLevelRaw,
            source: selection.source
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskRoleProfileEventTypes.selected,
            payload: encode(payload)
        ))
        AppLogger.audit(.roleProfileSelected, category: "RoleProfile", taskID: task.id, fields: auditFields(selection: selection))
    }

    static func auditFields(selection: TaskRoleProfileSelection) -> [String: String] {
        auditFields(profile: selection.profile, source: selection.source)
    }

    static func auditFields(profile: TaskRoleProfile, source: String) -> [String: String] {
        [
            "role": profile.role.rawValue,
            "runtime": profile.runtimeID,
            "model": profile.model,
            "budget": String(profile.tokenBudget),
            "policy_level": profile.policyLevelRaw,
            "source": source
        ]
    }

    private static func resolvedDefaultBudget(defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: AppStorageKeys.defaultTokenBudget) != nil else {
            return TaskExecutionDefaults.tokenBudget
        }
        return defaults.integer(forKey: AppStorageKeys.defaultTokenBudget)
    }

    private static func alternateVerifierRuntime(
        workerRuntime: AgentRuntimeID,
        providerSettings: AgentRuntimeProviderSettings
    ) -> AgentRuntimeID? {
        AgentRuntimeAdapterRegistry.runtimeIDs.first { runtime in
            runtime != workerRuntime &&
            !providerSettings.executablePath(for: runtime).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bumpRevision(defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: AppStorageKeys.roleProfileRevision) + 1,
                     forKey: AppStorageKeys.roleProfileRevision)
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
