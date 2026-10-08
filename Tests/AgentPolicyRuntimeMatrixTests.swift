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

    // Ask asks before anything with an effect (docs/specs/2026-10-07-permission-levels-harmonization.md),
    // so a destructive or publishing command is a question, not a refusal, on
    // every runtime. `sudo` is the one exception: it cannot prompt in a
    // non-interactive run.
    @Test("Ask asks before destructive and publishing commands; sudo stays denied")
    func askAsksBeforeEffectsInsteadOfRefusing() {
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, level: .review))
            for command in ["rm -rf build", "git push origin main", "chmod +x script.sh"] {
                #expect(
                    guardrail.disposition(toolName: "Bash", command: command) == .ask,
                    "\(runtime.rawValue) Ask \(command)"
                )
            }
            #expect(guardrail.disposition(toolName: "Bash", command: "sudo ls") == .denied, "\(runtime.rawValue) sudo")
        }
    }

    // Local tools used to be pre-granted on Codex, Cursor, Antigravity and
    // OpenCode while Claude and Copilot asked for the same command, so Ask meant
    // a different thing per runtime. It now asks on every one.
    @Test("Ask pre-grants no local tool on any runtime; the build preset still does")
    func askPreGrantsNoLocalTool() {
        let tools = ["bq", "astra-browser"]
        for runtime in Self.autonomousFlags.keys {
            let ask = Self.render(runtime: runtime, level: .review, localToolCommands: tools)
            #expect(!ask.allowedShellPatterns.contains { $0.hasPrefix("bq") || $0.hasPrefix("astra-browser") }, "\(runtime.rawValue)")
            #expect(!ask.allowedTools.contains { $0.contains("bq") || $0.contains("astra-browser") }, "\(runtime.rawValue)")
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, level: .review, localToolCommands: tools))
            #expect(guardrail.disposition(toolName: "Bash", command: "astra-browser click --ref 12") == .ask, "\(runtime.rawValue)")
        }
        for runtime in [AgentRuntimeID.codexCLI, .cursorCLI, .antigravityCLI, .openCodeCLI] {
            let build = Self.render(runtime: runtime, level: .build, localToolCommands: tools)
            #expect(build.allowedShellPatterns.contains("bq *"), "\(runtime.rawValue) build")
        }
    }

    // Custom keeps the user's per-item rules for local work, but actions outside
    // ASTRA follow Ask: a rule that allows Bash or `git:*` must not let
    // `git push` through unasked on any runtime.
    @Test("Custom rules that allow Bash or git still ask before a push")
    func customAsksBeforeExternalCommandsItsRulesAllow() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["git:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: policy))
            #expect(guardrail.disposition(toolName: "Bash", command: "git status") == .allowed, "\(runtime.rawValue) local git")
            #expect(
                guardrail.disposition(toolName: "Bash", command: "git push origin main") == .ask,
                "\(runtime.rawValue) push"
            )
        }
        // Not only Git: anything the shared risk classifier calls a write
        // outside this machine asks, while local writes and reads keep the rule.
        let wider = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["git:*", "curl:*", "gcloud:*", "gh:*", "npm:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: wider))
            for command in [
                "curl -X POST https://hooks.example.test/build -d ok",
                "curl --json '{\"build\":1}' https://hooks.example.test/api",
                "gcloud run deploy api --source .",
                "gh workflow run deploy.yml",
                "gh secret set TOKEN",
                "gh run cancel 12345",
                "npm unpublish widget@1.0.0",
                "npm deprecate widget@1.0.0 obsolete",
                "npm dist-tag add widget@1.0.0 beta"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in [
                "curl https://example.test/status", "gcloud compute instances list", "git commit -m wip",
                "gh workflow list", "gh run view 12345", "npm dist-tag ls widget", "npm install"
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .allowed, "\(runtime.rawValue) \(command)")
            }
        }

        // Approving a read is not approving a write to the same host: the
        // host-scoped read grant must not stand in for asking.
        let readApproval = PermissionBroker.approvalGrants(
            for: .shell(command: "curl https://example.test/status", toolName: "Bash")
        )
        let afterRead = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: readApproval
        ))
        #expect(afterRead.disposition(toolName: "Bash", command: "curl -d x https://example.test/delete") == .ask)
        let writeApproval = PermissionBroker.approvalGrants(
            for: .shell(command: "curl -d x https://example.test/delete", toolName: "Bash")
        )
        let afterWrite = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: wider, approvalGrants: writeApproval
        ))
        #expect(afterWrite.disposition(toolName: "Bash", command: "curl -d x https://example.test/delete") == .allowed,
                "an approved write is not asked about again")

        // A shell run with -c runs its payload: a rule allowing the shell
        // does not cover what the payload does outside this machine.
        let interpreter = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            allowedShellPatterns: ["bash:*", "sh:*", "zsh:*"]
        )
        for runtime in Self.autonomousFlags.keys {
            let guardrail = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: runtime, policy: interpreter))
            for command in [
                "bash -c 'curl -d x https://example.test/hook'",
                "sh -c \"git push origin main\"",
                "zsh -ec 'gh workflow run deploy.yml'",
                "bash -c \"bash -c 'gh pr create --fill'\"",
                "bash -c \"echo \\\"done\\\" && curl --json '{}' https://example.test/hook\""
            ] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) == .ask, "\(runtime.rawValue) \(command)")
            }
            for command in ["bash -c 'make test'", "sh -c \"echo 'git push' > notes.txt\"", "bash scripts/build.sh"] {
                #expect(guardrail.disposition(toolName: "Bash", command: command) != .ask, "\(runtime.rawValue) \(command)")
            }
        }
        let wrapped = "bash -c 'curl -d x https://example.test/hook'"
        let asked = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: interpreter))
            .violation(for: .toolUse(name: "Bash", id: "tool-1", input: ["command": wrapped]))
        #expect(asked?.requiresApproval == true)
        #expect(
            asked?.permissionRequest == .shell(command: "curl -d x https://example.test/hook", toolName: "Bash"),
            "the payload is what is asked about"
        )
        let payloadApproved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode, policy: interpreter, approvalGrants: asked?.approvalGrants ?? []
        ))
        #expect(payloadApproved.disposition(toolName: "Bash", command: wrapped) == .allowed,
                "approving the wrapped write does not ask again")

        // A command that only mentions one in a quoted operand runs nothing
        // outside ASTRA and keeps the rule.
        let mentioning = AgentRuntimePolicyGuard(manifest: Self.manifest(runtime: .claudeCode, policy: policy))
        #expect(mentioning.disposition(toolName: "Bash", command: "git log --grep 'git push'") == .allowed)

        let request = PermissionRequest.shell(command: "git push origin main", toolName: "Bash")
        let approved = AgentRuntimePolicyGuard(manifest: Self.manifest(
            runtime: .claudeCode,
            policy: policy,
            approvalGrants: PermissionBroker.approvalGrants(for: request)
        ))
        #expect(approved.disposition(toolName: "Bash", command: "git push origin main") == .allowed, "approved once, not asked twice")
    }

    // MARK: - Helpers

    private static func manifest(
        runtime: AgentRuntimeID,
        policy: AgentPolicy,
        approvalGrants: [PermissionGrant] = []
    ) -> RunPermissionManifest {
        let adapter = ProviderPolicyAdapterRegistry.adapter(
            for: runtime,
            runtimeCapabilities: AgentRuntimePolicyCapabilities(copilotCLI: copilotCapabilities)
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
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: runtime,
            providerVersion: nil,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            policyLevel: policy.level,
            policyScope: .builtInDefault,
            providerRender: adapter.render(policy: policy, context: context),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: approvalGrants
        )
    }

    private static let copilotCapabilities = CopilotCLICapabilities(helpText: """
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

    private static func manifest(
        runtime: AgentRuntimeID,
        level: AgentPolicyLevel,
        localToolCommands: [String] = []
    ) -> RunPermissionManifest {
        RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "run",
            providerID: runtime,
            providerVersion: nil,
            model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
            policyLevel: level,
            policyScope: .builtInDefault,
            providerRender: render(runtime: runtime, level: level, localToolCommands: localToolCommands),
            workspacePath: "/tmp/astra-policy-matrix",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: []
        )
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func render(
        runtime: AgentRuntimeID,
        level: AgentPolicyLevel,
        localToolCommands: [String] = []
    ) -> ProviderPolicyRender {
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
            localToolCommands: localToolCommands,
            environmentKeyNames: [],
            credentialLabels: [],
            providerFeatures: adapter.supportedFeatures
        )
        return adapter.render(policy: .preset(level), context: context)
    }
}
