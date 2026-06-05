import Foundation
import ASTRACore

enum ClaudeSettingsStore {
    private static let astraMetadataKey = "_astra_policy"

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
        var mergedPermissions = settings["permissions"] as? [String: Any] ?? [:]
        for (key, value) in permissions {
            mergedPermissions[key] = value
        }
        settings["permissions"] = mergedPermissions
        settings[astraMetadataKey] = [
            "version": 1,
            "managedPermissions": true,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        return writeSettings(settings, workspacePath: workspacePath, fileManager: fileManager)
    }

    static func configOwnership(at workspacePath: String, fileManager: FileManager = .default) -> PolicyConfigOwnership {
        let settings = loadSettings(workspacePath: workspacePath, fileManager: fileManager)
        guard !settings.isEmpty else { return .generated }

        let hasASTRAMetadata = settings[astraMetadataKey] != nil
        let hasPermissions = settings["permissions"] != nil
        let userOwnedKeys = Set(settings.keys).subtracting([astraMetadataKey, "permissions", "hooks"])

        if hasASTRAMetadata {
            return userOwnedKeys.isEmpty ? .generated : .mixed
        }
        if hasPermissions {
            return userOwnedKeys.isEmpty ? .userOverride : .mixed
        }
        return .mixed
    }

    static func existingConfigSummary(at workspacePath: String, fileManager: FileManager = .default) -> String? {
        let settings = loadSettings(workspacePath: workspacePath, fileManager: fileManager)
        guard !settings.isEmpty else { return nil }

        var parts: [String] = []
        if let permissions = settings["permissions"] as? [String: Any] {
            let allowCount = (permissions["allow"] as? [Any])?.count ?? 0
            let denyCount = (permissions["deny"] as? [Any])?.count ?? 0
            parts.append("permissions allow=\(allowCount) deny=\(denyCount)")
        }
        if let hooks = settings["hooks"] as? [String: Any] {
            parts.append("hooks=\(hooks.keys.count)")
        }
        let extraKeys = settings.keys
            .filter { ![astraMetadataKey, "permissions", "hooks"].contains($0) }
            .sorted()
        if !extraKeys.isEmpty {
            parts.append("preserved keys: \(extraKeys.joined(separator: ", "))")
        }
        return parts.isEmpty ? "Existing Claude settings detected" : parts.joined(separator: "; ")
    }

    static func generatedConfigPreview(policy: PermissionPolicy, allowedTools: [String]) -> String {
        let permissions = policy.subAgentPermissions(allowedTools: allowedTools).first ?? [:]
        let settings: [String: Any] = [
            "permissions": permissions,
            astraMetadataKey: [
                "version": 1,
                "managedPermissions": true
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
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

    static func loadSettings(
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
