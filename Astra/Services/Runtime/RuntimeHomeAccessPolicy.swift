import Foundation
import ASTRACore

/// Provider-owned startup layout. History is never enumerated. Environment
/// overrides replace the default location rather than adding a second home.
struct RuntimeHomeAccessPolicy: Sendable {
    struct Root: Sendable {
        var variable: String? = nil
        var fallback: String
        var suffix = ""
        var writable = true
        var createIfMissing: Bool? = nil
        var linuxFallbackVariable: String? = nil
        var linuxFallbackSuffix = ""
        var files: [String] = []
        var directories: [String] = []
        var fileOverrides: [String: String] = [:]
        var fallbacks: [String: String] = [:]

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

    func homeFilePaths(environment: [String: String], userHome: String) -> [String] {
        let base = homeFilesOverrideVariable.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? userHome
        return homeFiles.map { (base as NSString).appendingPathComponent($0) }
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
        .init(roots: [.init(variable: "COPILOT_HOME", fallback: ".copilot", writable: false, createIfMissing: true,
                           files: CopilotHomeAccessCheck.startupEntries.filter { $0.value == .file }.map(\.key).sorted(),
                           directories: ["session-state"],
                           fileOverrides: [CopilotHomeAccessCheck.providersFileName: CopilotHomeAccessCheck.providersOverrideVariable],
                           fallbacks: ["permissions-config": "permissions-config.json"])])
    }
}

extension AntigravityCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(fallback: ".gemini", files: ["settings.json", "oauth_creds.json", "config/mcp_config.json", "antigravity-cli/settings.json"]),
                      .init(fallback: ".antigravity")], configuredHomeVariable: "HOME")
    }
}

extension CodexCLIRuntimeAdapter {
    var homeAccessPolicy: RuntimeHomeAccessPolicy {
        .init(roots: [.init(variable: "CODEX_HOME", fallback: ".codex", files: ["config.toml", "auth.json"], directories: ["sessions"])], configuredHomeVariable: "CODEX_HOME")
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
                      .init(variable: "XDG_DATA_HOME", fallback: ".local/share", suffix: "opencode", files: ["auth.json"]),
                      .init(variable: "XDG_STATE_HOME", fallback: ".local/state", suffix: "opencode"),
                      .init(variable: "XDG_CACHE_HOME", fallback: ".cache", suffix: "opencode")], environmentFiles: ["OPENCODE_CONFIG"])
    }
}
