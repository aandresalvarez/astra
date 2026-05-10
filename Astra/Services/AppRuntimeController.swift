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
        defaultRuntimeID: String,
        timeoutSeconds: Int,
        validationModel: String,
        skipPermissions: Bool
    ) {
        let runtime = AgentRuntimeID(rawValue: defaultRuntimeID) ?? .claudeCode
        taskQueue.applySettings(
            claudePath: claudePath.isEmpty ? nil : claudePath,
            copilotPath: copilotPath.isEmpty ? nil : copilotPath,
            copilotHome: CopilotCLIRuntime.channelHome(),
            defaultRuntimeID: runtime,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            validationModel: validationModel,
            skipPermissions: skipPermissions
        )
    }

    func startScheduler(modelContext: ModelContext) {
        taskScheduler.start(modelContext: modelContext, taskQueue: taskQueue)
    }

    func loadPluginCatalog() {
        pluginCatalog.loadApprovedCapabilities()
    }

    func backfillThreadTitlesIfNeeded(
        coordinator: TaskLifecycleCoordinator,
        claudePath: String,
        copilotPath: String,
        defaultRuntimeID: String,
        validationModel: String,
        isUITestingSeededLaunch: Bool
    ) {
        guard !hasStartedThreadTitleBackfill, !isUITestingSeededLaunch else { return }
        hasStartedThreadTitleBackfill = true
        coordinator.backfillGeneratedThreadTitles(
            claudePath: claudePath,
            copilotPath: copilotPath,
            defaultRuntimeID: defaultRuntimeID,
            model: validationModel
        )
    }
}
