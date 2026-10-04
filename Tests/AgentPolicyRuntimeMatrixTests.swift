import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The runtime × policy-level contract. Each runtime's flag builder is tested on
/// its own elsewhere; this pins the whole grid so a change to the shared
/// resolver, a preset, or one adapter cannot silently move a level in another
/// runtime. What it protects:
///
/// - Only Auto renders the runtime's bypass flags, and always does.
/// - Ask and the legacy presets never carry a bypass flag, and keep the
///   provider's own sandbox switched on where the provider has one.
/// - Ask never hands a runtime write or shell grants it was not given.
@Suite("Policy runtime matrix")
struct AgentPolicyRuntimeMatrixTests {
    /// What each runtime must lead with for Auto.
    private static let autonomousFlags: [AgentRuntimeID: [String]] = [
        .claudeCode: ["--dangerously-skip-permissions"],
        .copilotCLI: ["--allow-all"],
        .antigravityCLI: ["--dangerously-skip-permissions"],
        .codexCLI: ["--dangerously-bypass-approvals-and-sandbox"],
        .cursorCLI: ["--force", "--sandbox", "disabled"],
        .openCodeCLI: ["--dangerously-skip-permissions"]
    ]

    /// Every spelling a provider uses to turn its own gate off.
    private static let bypassSpellings = [
        "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox",
        "--allow-all", "--yolo", "--force", "danger-full-access", "disabled"
    ]

    @Test("The matrix covers every registered runtime")
    func matrixCoversEveryRegisteredRuntime() {
        // A new runtime fails here until its Auto flags are declared above.
        #expect(Set(AgentRuntimeAdapterRegistry.runtimeIDs) == Set(Self.autonomousFlags.keys))
    }

    @Test("Auto renders the runtime's bypass flags and is the only broad level")
    func autonomousIsTheOnlyBroadLevel() {
        for (runtime, flags) in Self.autonomousFlags {
            for level in AgentPolicyLevel.allCases {
                let render = Self.render(runtime: runtime, level: level)
                if level == .autonomous {
                    #expect(Array(render.cliArgumentsSummary.prefix(flags.count)) == flags, "\(runtime.rawValue) Auto")
                    #expect(render.usesBroadProviderPermissions, "\(runtime.rawValue) Auto is broad")
                } else {
                    #expect(!render.usesBroadProviderPermissions, "\(runtime.rawValue) \(level.rawValue) is not broad")
                }
            }
        }
    }

    @Test("No level other than Auto carries a bypass flag")
    func onlyAutonomousCarriesBypassFlags() {
        for runtime in Self.autonomousFlags.keys {
            for level in AgentPolicyLevel.allCases where level != .autonomous {
                let args = Self.render(runtime: runtime, level: level).cliArgumentsSummary
                for spelling in Self.bypassSpellings {
                    #expect(
                        !args.contains { $0.contains(spelling) },
                        "\(runtime.rawValue) \(level.rawValue) must not carry \(spelling): \(args)"
                    )
                }
            }
        }
    }

    @Test("Providers with their own sandbox keep it on below Auto")
    func providerSandboxStaysOnBelowAuto() {
        for level in AgentPolicyLevel.allCases where level != .autonomous {
            let agy = Self.render(runtime: .antigravityCLI, level: level).cliArgumentsSummary
            #expect(agy == ["--sandbox"], "Antigravity \(level.rawValue)")

            let cursor = Self.render(runtime: .cursorCLI, level: level).cliArgumentsSummary
            #expect(Self.value(after: "--sandbox", in: cursor) == "enabled", "Cursor \(level.rawValue)")

            let codex = Self.render(runtime: .codexCLI, level: level).cliArgumentsSummary
            let mode = Self.value(after: "--sandbox", in: codex)
            #expect(mode == "read-only" || mode == "workspace-write", "Codex \(level.rawValue)")
            #expect(codex.contains(#"approval_policy="never""#), "Codex \(level.rawValue) pins approvals")
        }
    }

    @Test("Codex Ask can write the workspace and nothing wider; locked and Custom are read-only")
    func codexSandboxModePerLevel() {
        func mode(_ level: AgentPolicyLevel) -> String? {
            Self.value(after: "--sandbox", in: Self.render(runtime: .codexCLI, level: level).cliArgumentsSummary)
        }
        #expect(mode(.review) == "workspace-write")
        #expect(mode(.locked) == "read-only")
        #expect(mode(.custom) == "read-only")
    }

    @Test("Cursor Custom asks first; Ask does not leave the sandbox")
    func cursorCustomUsesAskMode() {
        let custom = Self.render(runtime: .cursorCLI, level: .custom).cliArgumentsSummary
        #expect(Self.value(after: "--mode", in: custom) == "ask")
        let review = Self.render(runtime: .cursorCLI, level: .review).cliArgumentsSummary
        #expect(!review.contains("--mode"))
    }

    @Test("Claude Ask leaves writes, shell and web to live approval")
    func claudeAskDefersGatedToolsToApproval() {
        let render = Self.render(runtime: .claudeCode, level: .review)
        #expect(!render.cliArgumentsSummary.contains("--dangerously-skip-permissions"))
        let preset = AgentPolicy.preset(.review)
        #expect(Set(preset.askFirstTools).isSuperset(of: ["Write", "Edit", "Bash", "WebFetch"]))
        #expect(Set(preset.allowedTools).isDisjoint(with: ["Write", "Edit", "MultiEdit", "Bash"]))
    }

    @Test("Copilot Ask and locked grant no write and no shell")
    func copilotAskGrantsNoWriteOrShell() {
        for level in [AgentPolicyLevel.locked, .review] {
            let args = Self.render(runtime: .copilotCLI, level: level).cliArgumentsSummary
            #expect(args.first == "--allow-tool", "Copilot \(level.rawValue)")
            #expect(!args.contains("write"), "Copilot \(level.rawValue) must not allow write")
            #expect(!args.contains { $0.hasPrefix("shell(") }, "Copilot \(level.rawValue) must not allow shell")
        }
    }

    @Test("Copilot grants widen with the level: Ask, then Build, then Network")
    func copilotGrantsWidenWithTheLevel() {
        func grants(_ level: AgentPolicyLevel) -> Set<String> {
            Set(Self.render(runtime: .copilotCLI, level: level).cliArgumentsSummary.dropFirst())
        }
        #expect(grants(.review).isStrictSubset(of: grants(.build)))
        #expect(grants(.build).isStrictSubset(of: grants(.network)))
    }

    // MARK: - Helpers

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func render(runtime: AgentRuntimeID, level: AgentPolicyLevel) -> ProviderPolicyRender {
        let copilot = CopilotCLICapabilities(helpText: """
        --allow-all
        --allow-all-tools
        --allow-all-paths
        --allow-all-urls
        --available-tools
        --excluded-tools
        --output-format
        --stream
        --no-ask-user
        --secret-env-vars
        """)
        let adapter = ProviderPolicyAdapterRegistry.adapter(
            for: runtime,
            runtimeCapabilities: AgentRuntimePolicyCapabilities(copilotCLI: copilot)
        )
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            requestedAllowedTools: ["Read", "Grep"],
            localToolCommands: [],
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )
        return adapter.render(policy: .preset(level), context: context)
    }
}
