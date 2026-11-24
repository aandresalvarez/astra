import Foundation
import ASTRACore
import ASTRAModels

/// Injects a task's template hooks into its checkout's
/// `.claude/settings.local.json` for one launch and restores the file after.
/// A launch `TemplateHookInjectionPolicy` rules out touches nothing, on the
/// way in or out.
final class RuntimeTemplateHookScope {
    private let hooks: String
    private let path: String
    private let injected: Bool
    private let backup: Data?
    init(
        task: AgentTask,
        path: String,
        runtime: AgentRuntimeID,
        workspaceAccess: TaskExecutionResourceAccess,
        lease: [TaskResourceLockClaim]? = nil
    ) {
        self.hooks = task.templateHooksJSON
        self.path = path
        self.injected = TemplateHookInjectionPolicy.injects(
            hooksJSON: hooks, runtime: runtime, workspaceAccess: workspaceAccess, path: path, lease: lease)
        self.backup = injected ? ClaudeSettingsStore.injectTemplateHooks(hooksJSON: hooks, workspacePath: path) : nil
        if !injected, TemplateHookInjectionPolicy.hasHooks(hooks) {
            let readsSettings = TemplateHookInjectionPolicy.readsCheckoutSettings(runtime)
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "source": "template_hooks",
                "result": "skipped",
                "runtime": runtime.rawValue,
                "reason": readsSettings ? "workspace_not_held_exclusively" : "runtime_ignores_checkout_settings"
            ], level: readsSettings ? .warning : .debug)
        }
    }
    func restore() {
        guard injected else { return }
        ClaudeSettingsStore.restoreTemplateHooks(hooksJSON: hooks, workspacePath: path, backup: backup)
    }
}
