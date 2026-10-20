import Foundation
import ASTRACore

/// Provider-owned startup layout. History is never enumerated. Environment
/// overrides replace the default location rather than adding a second home.
struct RuntimeHomeAccessPolicy: Sendable {
    struct StateFile: Sendable {
        let name: String
        var overrideVariable: String? = nil
        var companionSuffixes: [String] = []
        var requiresPrivateOwner = false

        func path(environment: [String: String], directory: String) -> String {
            let override = overrideVariable.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            let value = override ?? name
            return value.hasPrefix("/") ? value : (directory as NSString).appendingPathComponent(value)
        }

        func paths(environment: [String: String], directory: String) -> [String] {
            let primary = path(environment: environment, directory: directory)
            return [primary] + companionSuffixes.map { primary + $0 }
        }
    }
    struct ResumedState: Sendable {
        let directory: String
        var fileSuffix: String? = nil
        var isDirectory: Bool { fileSuffix == nil }
        func path(root: String, sessionID: String) -> String {
            ((root as NSString).appendingPathComponent(directory) as NSString).appendingPathComponent(sessionID + (fileSuffix ?? ""))
        }
    }
    static let openCodeDatabase = StateFile(name: "opencode.db", overrideVariable: "OPENCODE_DB", companionSuffixes: ["-wal", "-shm"], requiresPrivateOwner: true)
    static let copilotDatabase = StateFile(name: "session-store.db", companionSuffixes: ["-wal", "-shm"])
    static let antigravityConversation = ResumedState(directory: "antigravity-cli/conversations", fileSuffix: ".db")

    struct Root: Sendable {
        var variable: String? = nil
        var fallback: String
        var onlyWhenConfigured = false
        var suffix = ""
        var writable = true
        var createIfMissing: Bool? = nil
        var linuxFallbackVariable: String? = nil
        var linuxFallbackSuffix = ""
        var files: [String] = []
        var directories: [String] = []
        var stateFiles: [StateFile] = []
        var resumedState: ResumedState? = nil
        var fileOverrides: [String: String] = [:]
        var fallbacks: [String: String] = [:]

        func isEnabled(environment: [String: String]) -> Bool {
            !onlyWhenConfigured || variable.flatMap { environment[$0] }.map { !$0.isEmpty } == true
        }

        func path(environment: [String: String], userHome: String, workingDirectory: String) -> String {
            let value = variable.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
                ?? (userHome as NSString).appendingPathComponent(fallback)
            let absolute = value.hasPrefix("/") ? value : (workingDirectory as NSString).appendingPathComponent(value)
            return suffix.isEmpty ? absolute : (absolute as NSString).appendingPathComponent(suffix)
        }
    }

    var roots: [Root] = []
    var homeFiles: [String] = []
    var homeFilesOverrideVariable: String? = nil
    var environmentFiles: [String] = []
    var configuredHomeVariable: String? = nil
    static let none = Self()

    func homeFilePaths(environment: [String: String], userHome: String, workingDirectory: String) -> [String] {
        let base = homeFilesOverrideVariable.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? userHome
        let absolute = base.hasPrefix("/") ? base : (workingDirectory as NSString).appendingPathComponent(base)
        return homeFiles.map { (absolute as NSString).appendingPathComponent($0) }
    }
}

extension AgentRuntimeAdapterRegistry {
    static func homeAccessPolicy(for runtime: AgentRuntimeID) -> RuntimeHomeAccessPolicy {
        adapterIfRegistered(for: runtime)?.homeAccessPolicy ?? .none
    }
}

extension ClaudeCodeRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(variable: "CLAUDE_CONFIG_DIR", fallback: ".claude", files: ["settings.json", ".credentials.json"])],
              homeFiles: [".claude.json"], homeFilesOverrideVariable: "CLAUDE_CONFIG_DIR")
    }
}

extension CopilotCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        // Native host launches use CopilotHomeAccessCheck's richer diagnosis.
        // The same declared startup set is used inside containers.
        let mutable = RuntimeHomeAccessPolicy.copilotDatabase
        let mutableNames = Set([mutable.name] + mutable.companionSuffixes.map { mutable.name + $0 })
        return .init(roots: [.init(variable: "COPILOT_HOME", fallback: ".copilot", createIfMissing: true,
                           files: CopilotHomeAccessCheck.startupEntries.filter { $0.value == .file && !mutableNames.contains($0.key) }.map(\.key).sorted(),
                           directories: ["session-state"],
                           stateFiles: [mutable], resumedState: .init(directory: "session-state"),
                           fileOverrides: [CopilotHomeAccessCheck.providersFileName: CopilotHomeAccessCheck.providersOverrideVariable],
                           fallbacks: ["permissions-config": "permissions-config.json"])])
    }
}

extension AntigravityCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(fallback: ".gemini", files: ["settings.json", "oauth_creds.json", "config/mcp_config.json", "antigravity-cli/settings.json"],
                           resumedState: RuntimeHomeAccessPolicy.antigravityConversation),
                      .init(fallback: ".antigravity")], configuredHomeVariable: "HOME")
    }
}

extension CodexCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        // Both initial and resumed ASTRA commands pass --ignore-user-config.
        // config.toml is not a launch dependency; auth and session state are.
        .init(roots: [.init(variable: "CODEX_HOME", fallback: ".codex", files: ["auth.json"], directories: ["sessions"])], configuredHomeVariable: "CODEX_HOME")
    }
}

extension CursorCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(variable: "CURSOR_CONFIG_DIR", fallback: ".cursor", linuxFallbackVariable: "XDG_CONFIG_HOME", linuxFallbackSuffix: "cursor", files: ["cli-config.json", "mcp.json"])])
    }
}

extension OpenCodeCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(variable: "XDG_CONFIG_HOME", fallback: ".config", suffix: "opencode", writable: false, files: ["opencode.json", "opencode.jsonc"]),
                      .init(variable: "XDG_DATA_HOME", fallback: ".local/share", suffix: "opencode", files: ["auth.json"], stateFiles: [RuntimeHomeAccessPolicy.openCodeDatabase]),
                      .init(variable: "XDG_STATE_HOME", fallback: ".local/state", suffix: "opencode"),
                      .init(variable: "XDG_CACHE_HOME", fallback: ".cache", suffix: "opencode"),
                      .init(variable: "OPENCODE_CONFIG_DIR", fallback: "", onlyWhenConfigured: true, writable: false,
                            files: ["opencode.json", "opencode.jsonc"])], environmentFiles: ["OPENCODE_CONFIG"])
    }
}
