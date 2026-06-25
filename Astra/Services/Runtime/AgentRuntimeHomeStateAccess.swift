import Foundation
import ASTRACore

struct AgentRuntimeHomeStateAccess: Equatable, Sendable {
    static let managedHomeWritableRelativePaths = [
        ".config",
        ".cache",
        ".npm",
        ".local/share",
        ".local/state",
        "Library/Caches"
    ]

    static let none = AgentRuntimeHomeStateAccess(
        explicitHomeWritableRelativePaths: [],
        inheritedHomeWritableRelativePaths: []
    )
    static let claudeCode = providerState([
        ".claude",
        ".claude.json",
        "Library/Application Support/Claude"
    ])
    static let copilotCLI = AgentRuntimeHomeStateAccess(
        explicitHomeWritableRelativePaths: managedHomeWritableRelativePaths,
        inheritedHomeWritableRelativePaths: [
            ".copilot",
            "Library/Caches/copilot"
        ]
    )
    static let antigravityCLI = providerState([
        ".antigravity",
        ".gemini"
    ])
    static let codexCLI = providerState([".codex"])
    static let cursorCLI = providerState([".cursor"])
    static let openCodeCLI = xdgApplicationState("opencode")

    let explicitHomeWritableRelativePaths: [String]
    let inheritedHomeWritableRelativePaths: [String]

    init(
        explicitHomeWritableRelativePaths: [String],
        inheritedHomeWritableRelativePaths: [String]
    ) {
        self.explicitHomeWritableRelativePaths = Self.normalizedRelativePaths(explicitHomeWritableRelativePaths)
        self.inheritedHomeWritableRelativePaths = Self.normalizedRelativePaths(inheritedHomeWritableRelativePaths)
    }

    static func providerState(
        _ providerRelativePaths: [String],
        explicitManagedHomeWritableRelativePaths: [String] = managedHomeWritableRelativePaths
    ) -> AgentRuntimeHomeStateAccess {
        AgentRuntimeHomeStateAccess(
            explicitHomeWritableRelativePaths: explicitManagedHomeWritableRelativePaths + providerRelativePaths,
            inheritedHomeWritableRelativePaths: providerRelativePaths
        )
    }

    static func xdgApplicationState(_ name: String) -> AgentRuntimeHomeStateAccess {
        let appPaths = [
            ".config/\(name)",
            ".cache/\(name)",
            ".local/share/\(name)",
            ".local/state/\(name)"
        ]
        return providerState(appPaths)
    }

    var isEmpty: Bool {
        explicitHomeWritableRelativePaths.isEmpty && inheritedHomeWritableRelativePaths.isEmpty
    }

    private static func normalizedRelativePaths(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("/"),
                  !trimmed.contains("\n"),
                  seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }
}

protocol AgentRuntimeSandboxContract {
    var homeStateAccess: AgentRuntimeHomeStateAccess { get }
}

extension AgentRuntimeSandboxContract {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .none }
}

extension AgentRuntimeAdapterRegistry {
    static func homeStateAccess(for runtime: AgentRuntimeID) -> AgentRuntimeHomeStateAccess {
        adapterIfRegistered(for: runtime)?.homeStateAccess ?? .none
    }
}

extension ClaudeCodeRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .claudeCode }
}

extension CopilotCLIRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .copilotCLI }
}

extension AntigravityCLIRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .antigravityCLI }
}

extension CodexCLIRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .codexCLI }
}

extension CursorCLIRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .cursorCLI }
}

extension OpenCodeCLIRuntimeAdapter {
    var homeStateAccess: AgentRuntimeHomeStateAccess { .openCodeCLI }
}
