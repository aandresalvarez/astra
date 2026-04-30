import Foundation

enum ClaudeSettingsStore {
    static func settingsDirectory(for workspacePath: String) -> String {
        guard !workspacePath.isEmpty else { return "" }
        return (workspacePath as NSString).appendingPathComponent(".claude")
    }

    static func settingsPath(for workspacePath: String) -> String {
        let directory = settingsDirectory(for: workspacePath)
        guard !directory.isEmpty else { return "" }
        return (directory as NSString).appendingPathComponent("settings.local.json")
    }

    @discardableResult
    static func ensureSubAgentPermissions(
        at workspacePath: String,
        policy: PermissionPolicy,
        allowedTools: [String],
        fileManager: FileManager = .default
    ) -> Bool {
        let perms = policy.subAgentPermissions(allowedTools: allowedTools)
        guard let permissions = perms.first else { return false }

        var settings = loadSettings(workspacePath: workspacePath, fileManager: fileManager)
        settings["permissions"] = permissions
        return writeSettings(settings, workspacePath: workspacePath, fileManager: fileManager)
    }

    static func injectTemplateHooks(
        hooksJSON: String,
        workspacePath: String,
        fileManager: FileManager = .default
    ) -> Data? {
        guard !hooksJSON.isEmpty, hooksJSON != "{}" else { return nil }
        guard let hooksData = hooksJSON.data(using: .utf8),
              let hooks = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any] else {
            return nil
        }

        let path = settingsPath(for: workspacePath)
        guard !path.isEmpty else { return nil }
        let backup = fileManager.contents(atPath: path)
        var settings = loadSettings(workspacePath: workspacePath, fileManager: fileManager)

        var existingHooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]
        for (hookType, entries) in hooks {
            guard let entries = entries as? [[String: Any]] else { continue }
            var current = existingHooks[hookType] ?? []
            for entry in entries {
                var taggedEntry = entry
                taggedEntry["_astra_template"] = true
                current.append(taggedEntry)
            }
            existingHooks[hookType] = current
        }
        settings["hooks"] = existingHooks

        guard writeSettings(settings, workspacePath: workspacePath, fileManager: fileManager) else {
            return nil
        }
        return backup
    }

    static func restoreTemplateHooks(
        hooksJSON: String,
        workspacePath: String,
        backup: Data?,
        fileManager: FileManager = .default
    ) {
        guard backup != nil || !hooksJSON.isEmpty else { return }
        guard hooksJSON != "{}", !hooksJSON.isEmpty else { return }

        let path = settingsPath(for: workspacePath)
        guard !path.isEmpty else { return }

        var settings = loadSettings(workspacePath: workspacePath, fileManager: fileManager)
        if let backup,
           let backupSettings = parseSettings(data: backup) {
            if settings.isEmpty {
                settings = backupSettings
            } else if let originalHooks = backupSettings["hooks"] {
                settings["hooks"] = originalHooks
            } else {
                settings.removeValue(forKey: "hooks")
            }
        } else {
            removeTemplateHooks(from: &settings)
        }

        if settings.isEmpty {
            try? fileManager.removeItem(atPath: path)
        } else {
            _ = writeSettings(settings, workspacePath: workspacePath, fileManager: fileManager)
        }
    }

    private static func loadSettings(
        workspacePath: String,
        fileManager: FileManager
    ) -> [String: Any] {
        let path = settingsPath(for: workspacePath)
        guard !path.isEmpty,
              let data = fileManager.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return settings
    }

    private static func parseSettings(data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func removeTemplateHooks(from settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: [[String: Any]]] else { return }
        for (hookType, entries) in hooks {
            let filtered = entries.filter { entry in
                (entry["_astra_template"] as? Bool) != true
            }
            if filtered.isEmpty {
                hooks.removeValue(forKey: hookType)
            } else {
                hooks[hookType] = filtered
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    private static func writeSettings(
        _ settings: [String: Any],
        workspacePath: String,
        fileManager: FileManager
    ) -> Bool {
        let directory = settingsDirectory(for: workspacePath)
        let path = settingsPath(for: workspacePath)
        guard !directory.isEmpty, !path.isEmpty else { return false }
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}
