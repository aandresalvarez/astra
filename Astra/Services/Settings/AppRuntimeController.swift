import Foundation
import SwiftData
import ASTRACore

@Observable @MainActor
final class AppRuntimeController {
    let taskQueue: TaskQueue
    let taskScheduler: TaskScheduler
    let pluginCatalog: PluginCatalog
    let preflightCache: PreflightCache

    private var hasStartedThreadTitleBackfill = false
    private var hasRunStoreMaintenance = false

    init(
        poolSize: Int = UserDefaults.standard.object(forKey: "workerPoolSize") as? Int ?? 3,
        taskQueue: TaskQueue? = nil,
        taskScheduler: TaskScheduler? = nil,
        pluginCatalog: PluginCatalog? = nil,
        preflightCache: PreflightCache? = nil
    ) {
        self.taskQueue = taskQueue ?? TaskQueue(poolSize: poolSize)
        self.taskScheduler = taskScheduler ?? TaskScheduler()
        self.pluginCatalog = pluginCatalog ?? PluginCatalog()
        self.preflightCache = preflightCache ?? PreflightCache()
    }

    func applySettings(
        claudePath: String,
        copilotPath: String,
        providerSettings: AgentRuntimeProviderSettings = RuntimeProviderSettingsStore.settings(),
        defaultRuntimeID: String,
        timeoutSeconds: Int,
        validationModel: String,
        skipPermissions: Bool,
        defaultPolicyLevelRaw: String
    ) {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        taskQueue.applySettings(
            claudePath: claudePath.isEmpty ? nil : claudePath,
            copilotPath: copilotPath.isEmpty ? nil : copilotPath,
            copilotHome: CopilotCLIRuntime.channelHome(),
            providerSettings: providerSettings,
            defaultRuntimeID: runtime,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            validationModel: validationModel,
            skipPermissions: skipPermissions,
            defaultPolicyLevelRaw: defaultPolicyLevelRaw
        )
    }

    func startScheduler(modelContext: ModelContext) {
        taskScheduler.start(modelContext: modelContext, taskQueue: taskQueue)
    }

    func loadPluginCatalog() {
        pluginCatalog.loadApprovedCapabilities()
    }

    /// One-time-per-launch task-store housekeeping: prune abandoned low-signal
    /// drafts and remove duplicate session imports. Skipped during seeded UI
    /// test launches so fixtures stay deterministic.
    func runStoreMaintenanceIfNeeded(modelContext: ModelContext, isUITestingSeededLaunch: Bool) {
        guard !hasRunStoreMaintenance, !isUITestingSeededLaunch else { return }
        hasRunStoreMaintenance = true
        TaskStoreMaintenance.runStartupMaintenance(modelContext: modelContext)
    }

    func backfillThreadTitlesIfNeeded(
        coordinator: TaskLifecycleCoordinator,
        claudePath: String,
        copilotPath: String,
        providerSettings: AgentRuntimeProviderSettings = RuntimeProviderSettingsStore.settings(),
        defaultRuntimeID: String,
        validationModel: String,
        isUITestingSeededLaunch: Bool
    ) {
        guard !hasStartedThreadTitleBackfill, !isUITestingSeededLaunch else { return }
        hasStartedThreadTitleBackfill = true
        coordinator.backfillGeneratedThreadTitles(
            claudePath: claudePath,
            copilotPath: copilotPath,
            providerSettings: providerSettings,
            defaultRuntimeID: defaultRuntimeID,
            model: validationModel
        )
    }
}
