import Foundation
import ASTRAModels

final class RuntimeTemplateHookScope {
    private let hooks: String
    private let path: String
    private let backup: Data?
    init(task: AgentTask, path: String) {
        self.hooks = task.templateHooksJSON
        self.path = path
        self.backup = ClaudeSettingsStore.injectTemplateHooks(hooksJSON: hooks, workspacePath: path)
    }
    func restore() {
        ClaudeSettingsStore.restoreTemplateHooks(hooksJSON: hooks, workspacePath: path, backup: backup)
    }
}
