import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeAgentPolicyContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func policyRenderContext(
    runtime: AgentRuntimeID,
    features: ProviderPolicyFeatures,
    requestedAllowedTools: [String] = ["Read", "Grep"],
    localToolCommands: [String] = [],
    environmentKeyNames: [String] = [],
    credentialLabels: [String] = []
) -> PolicyRenderContext {
    PolicyRenderContext(
        runtimeID: runtime,
        model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
        workspacePath: "/tmp/astra-policy-tests",
        additionalPaths: [],
        requestedAllowedTools: requestedAllowedTools,
        localToolCommands: localToolCommands,
        environmentKeyNames: environmentKeyNames,
        credentialLabels: credentialLabels,
        providerFeatures: features
    )
}

private struct FutureProviderPolicyAdapterFixture: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .claudeCode
    let adapterVersion = 99

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: true,
            supportsDenyTools: false,
            supportsAskFirstMode: true,
            supportsPathScoping: false,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: true,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: false
        )
    }

    func render(policy _: AgentPolicy, context _: PolicyRenderContext) -> ProviderPolicyRender {
        fatalError("This fixture only exercises default ProviderPolicyAdapter grant mapping.")
    }
}

@Suite("Agent Policy")
struct AgentPolicyTests {
    @Test("Primary policy modes are ask auto and custom")
    func primaryPolicyModes() {
        #expect(AgentPolicyLevel.primaryCases == [.review, .autonomous, .custom])
        #expect(AgentPolicyLevel.customPresetCases == [.locked, .build, .network])
        #expect(AgentPolicyLevel.review.displayName == "Ask")
        #expect(AgentPolicyLevel.autonomous.displayName == "Auto")
        #expect(AgentPolicyLevel.build.userFacingLevel == .custom)
        #expect(AgentPolicyLevel.normalized("ask approval") == .review)
        #expect(AgentPolicyLevel.normalized("automatic") == .autonomous)
        #expect(AgentPolicyLevel.normalized("auto") == .autonomous)
        #expect(AgentPolicyLevel.normalized("read-only") == .locked)
        #expect(AgentPolicyLevel.normalized("network heavy") == .network)
    }

    @Test("Review is the useful conservative default")
    func reviewPreset() {
        let policy = AgentPolicy.preset(.review)

        #expect(policy.allowedTools.contains("Read"))
        #expect(policy.allowedTools.contains("Grep"))
        #expect(policy.askFirstTools.contains("Write"))
        #expect(policy.askFirstTools.contains("Bash"))
        #expect(policy.deniedShellPatterns.contains("rm:*"))
        #expect(policy.deniedShellPatterns.contains("sudo:*"))
    }

    @Test("Deny rules win over requested allowed tools")
    func denyWinsOverAllow() {
        let policy = AgentPolicy(
            level: .build,
            allowedTools: ["Read", "Bash"],
            deniedTools: ["Bash"]
        )

        let renderedTools = policy.providerAllowedTools(requestedTools: ["Bash", "Write"])

        #expect(renderedTools.contains("Read"))
        #expect(renderedTools.contains("Write"))
        #expect(!renderedTools.contains("Bash"))
    }

    @Test("Denied tools are matched case-insensitively")
    func deniedToolsAreMatchedCaseInsensitively() {
        let reviewPolicy = AgentPolicy(
            level: .review,
            allowedTools: ["Read", "Bash"],
            deniedTools: ["bash"]
        )
        #expect(reviewPolicy.providerAllowedTools(requestedTools: ["Bash"]) == ["Read"])

        let customPolicy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash(curl:*)"],
            deniedTools: ["bash(curl:*)"]
        )
        #expect(customPolicy.providerAllowedTools(requestedTools: []) == ["Read"])
    }

    @Test("One-run approvals clear matching ask-first and denied tools")
    func oneRunApprovalsClearMatchingAskFirstAndDeniedTools() {
        let policy = AgentPolicy(
            level: .review,
            allowedTools: ["Read"],
            askFirstTools: ["bash"],
            deniedTools: ["write"]
        )

        let approved = policy.applyingOneRunAllowedTools(["Bash", "Write"])

        #expect(approved.allowedTools.contains("Bash"))
        #expect(approved.allowedTools.contains("Write"))
        #expect(!approved.askFirstTools.contains("bash"))
        #expect(!approved.deniedTools.contains("write"))
    }

    @Test("Custom policy does not inherit skill requested tools")
    func customPolicyDoesNotInheritSkillRequestedTools() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read"],
            askFirstTools: ["Bash"],
            deniedTools: []
        )

        let renderedTools = policy.providerAllowedTools(requestedTools: ["Bash", "Write", "WebFetch"])

        #expect(renderedTools == ["Read"])

        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .claudeCode,
                features: adapter.supportedFeatures,
                requestedAllowedTools: ["Bash", "Write", "WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(render.allowedTools == ["Read"])
        #expect(!render.allowedTools.contains("Bash"))
        #expect(!render.allowedTools.contains("Write"))
        #expect(!render.allowedTools.contains("WebFetch"))
        #expect(!render.allowedTools.contains("Bash(gh *)"))
        #expect(render.askFirstTools.contains("Bash"))
    }

    @Test("Custom policy grants local CLI tools only with explicit Bash")
    func customPolicyGrantsLocalCLIToolsOnlyWithExplicitBash() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash"],
            askFirstTools: ["Write"],
            deniedTools: []
        )

        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                requestedAllowedTools: ["WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(claudeRender.allowedTools.contains("Bash"))
        #expect(claudeRender.allowedTools.contains("Bash(gh *)"))
        #expect(!claudeRender.allowedTools.contains("WebFetch"))

        let copilot = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: """
            --allow-tool
            --output-format
            """)
        ))
        let copilotRender = copilot.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                requestedAllowedTools: ["WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(!copilotRender.allowedTools.contains("fetch"))
    }

    @Test("Claude review render avoids broad provider permissions")
    func claudeReviewRender() {
        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(runtime: .claudeCode, features: adapter.supportedFeatures)
        )

        #expect(render.providerID == .claudeCode)
        #expect(render.policyLevel == .review)
        #expect(render.permissionMode == .restricted)
        #expect(render.allowedTools.contains("Read"))
        #expect(!render.allowedTools.contains("Write"))
        #expect(render.askFirstTools.contains("Bash"))
        #expect(render.settingsSummary.contains("allow=3 ask=6"))
        #expect(render.generatedConfigPreview.contains("Write(*)"))
        #expect(render.generatedConfigPreview.contains("Edit(*)"))
        #expect(render.generatedConfigPreview.contains("Bash(*)"))
        #expect(!render.usesBroadProviderPermissions)
        #expect(render.diagnostics.contains { $0.id == "claude.shell-deny-provider-native-gap" })
        #expect(!render.diagnostics.contains { $0.id == "claude.ask-checkpoints-brokered" })
    }

    @Test("Read-only locked policy stays in restricted provider mode")
    func lockedPolicyUsesRestrictedProviderMode() {
        let policy = AgentPolicy.preset(.locked)
        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: policy,
            context: policyRenderContext(runtime: .claudeCode, features: adapter.supportedFeatures)
        )

        #expect(ProviderPolicyModeResolver.mode(for: policy, runtime: .claudeCode) == .restricted)
        #expect(render.permissionMode == .restricted)
        #expect(render.allowedTools.contains("Read"))
        #expect(!render.allowedTools.contains("Write"))
        #expect(render.generatedConfigPreview.contains("Read(*)"))
        #expect(!render.generatedConfigPreview.contains("Write(*)"))
        #expect(!render.generatedConfigPreview.contains("Bash(*)"))
    }

    @Test("Relabeled read-only custom policy stays in restricted provider mode")
    func relabeledReadOnlyCustomPolicyStaysRestricted() {
        // AgentPolicyDefaults relabels a persisted `.locked` default to `.custom`
        // while preserving its denied tools/shell. That relabeled policy must
        // still resolve to `.restricted` so providers keep the generated
        // read-only allow/deny that enforced the read-only preset — not fall
        // through to `.interactive`, which drops it.
        var policy = AgentPolicy.preset(.locked)
        policy.level = .custom
        #expect(policy.deniedTools.contains("Write"))
        #expect(ProviderPolicyModeResolver.mode(for: policy, runtime: .claudeCode) == .restricted)
        // Consistent with the explicit `.locked` branch across providers.
        #expect(ProviderPolicyModeResolver.mode(for: policy, runtime: .codexCLI) == .restricted)

        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: policy,
            context: policyRenderContext(runtime: .claudeCode, features: adapter.supportedFeatures)
        )
        #expect(render.permissionMode == .restricted)
        #expect(render.generatedConfigPreview.contains("Read(*)"))
        #expect(!render.generatedConfigPreview.contains("Write(*)"))
    }

    @Test("Ask-style custom preset keeps interactive provider mode")
    func customAskPresetStaysInteractive() {
        // The default `.custom` preset expresses writes as ask-first (not denies)
        // and should keep deferring to the provider's interactive approval rather
        // than being forced to restricted.
        let policy = AgentPolicy.preset(.custom)
        #expect(policy.deniedTools.isEmpty)
        #expect(ProviderPolicyModeResolver.mode(for: policy, runtime: .claudeCode) == .interactive)
    }

    @Test("Copilot autonomous render uses allow-all only when capability supports it")
    func copilotAutonomousRenderUsesAllowAllWhenSupported() {
        let capabilities = CopilotCLICapabilities(helpText: """
        --allow-all
        --allow-all-tools
        --allow-all-paths
        --allow-all-urls
        --output-format
        --stream
        --no-ask-user
        --secret-env-vars
        """)
        let adapter = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(copilotCLI: capabilities))
        let render = adapter.render(
            policy: .preset(.autonomous),
            context: policyRenderContext(runtime: .copilotCLI, features: adapter.supportedFeatures)
        )

        #expect(render.providerID == .copilotCLI)
        #expect(render.policyLevel == .autonomous)
        #expect(render.cliArgumentsSummary.contains("--allow-all"))
        #expect(render.usesBroadProviderPermissions)
        #expect(render.diagnostics.contains { $0.id == "copilot_cli.autonomous-broad-permissions" })
    }

    @Test("Copilot review render records provider-native permission entries")
    func copilotReviewRenderRecordsProviderPermissions() {
        let capabilities = CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        --stream
        --no-ask-user
        """)
        let adapter = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(copilotCLI: capabilities))
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(runtime: .copilotCLI, features: adapter.supportedFeatures)
        )

        #expect(render.allowedTools == ["glob", "grep", "view"])
        #expect(render.generatedConfigPreview.contains("--allow-tool"))
        #expect(render.enforcementTiers.contains(.astraBrokered))
    }

    @Test("Copilot support tools are separate from task allow policy")
    func copilotSupportToolsAreSeparateFromTaskAllowPolicy() {
        let capabilities = CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        --stream
        --no-ask-user
        """)
        let adapter = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(copilotCLI: capabilities))
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(runtime: .copilotCLI, features: adapter.supportedFeatures)
        )
        let supportToolNames = render.runtimeSupportTools.map(\.name)

        #expect(supportToolNames == ["fetch_copilot_cli_documentation", "report_intent"])
        #expect(render.allowedTools == ["glob", "grep", "view"])
        #expect(!render.allowedTools.contains("fetch_copilot_cli_documentation"))
        #expect(!render.allowedTools.contains("report_intent"))
        #expect(render.cliArgumentsSummary.contains("fetch_copilot_cli_documentation"))
        #expect(render.cliArgumentsSummary.contains("report_intent"))
        #expect(render.generatedConfigPreview.contains("fetch_copilot_cli_documentation"))
        #expect(render.generatedConfigPreview.contains("report_intent"))
    }

    @Test("Observed policy events decode old JSON without input keys")
    func observedPolicyEventsDecodeOldJSONWithoutInputKeys() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "kind": "tool_use",
          "toolName": "report_intent",
          "summary": "provider intent"
        }
        """

        let decoded = try JSONDecoder().decode(PolicyObservedEvent.self, from: Data(json.utf8))

        #expect(decoded.inputKeys.isEmpty)
        #expect(decoded.toolName == "report_intent")
    }

    @Test("Provider adapters render typed one-run grants")
    func providerAdaptersRenderTypedOneRunGrants() {
        let grants: [PermissionGrant] = [
            .shellCommand(executable: "curl", pattern: "*"),
            .providerTool(name: "Write")
        ]

        let claude = ClaudePolicyAdapter()
        #expect(claude.providerGrantStrings(for: grants) == ["Bash(curl *)", "Write"])

        let copilot = CopilotPolicyAdapter(capabilities: .conservative)
        #expect(copilot.providerGrantStrings(for: grants) == ["shell(curl:*)", "write"])
        #expect(PermissionBroker.permissionGrant(fromProviderString: "Bash(*)") == nil)
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell") == nil)
    }

    @Test("Provider runtime grants include safe shell companions without broad authority")
    func providerRuntimeGrantsIncludeSafeShellCompanionsWithoutBroadAuthority() {
        let grants: [PermissionGrant] = [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ]

        let storedCopilotGrants = PermissionBroker.providerGrantStrings(for: grants, runtime: .copilotCLI)
        let runtimeCopilotGrants = PermissionBroker.providerRuntimeGrantStrings(for: grants, runtime: .copilotCLI)
        let runtimeClaudeGrants = PermissionBroker.providerRuntimeGrantStrings(for: grants, runtime: .claudeCode)

        #expect(storedCopilotGrants == ["shell(gh:search prs *)"])
        #expect(runtimeCopilotGrants.contains("shell(gh:search prs *)"))
        #expect(runtimeCopilotGrants.contains("shell(gh:auth status *)"))
        #expect(runtimeCopilotGrants.contains("shell(mkdir:-p *)"))
        #expect(!runtimeCopilotGrants.contains("shell(gh:*)"))
        #expect(!runtimeCopilotGrants.contains("shell(echo:*)"))
        #expect(runtimeClaudeGrants.contains("Bash(gh auth status *)"))
        #expect(!runtimeClaudeGrants.contains("Bash(gh *)"))
    }

    @Test("One-run execution policy carries runtime companion grants")
    func oneRunExecutionPolicyCarriesRuntimeCompanionGrants() {
        let grants: [PermissionGrant] = [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ]

        let policy = PermissionBroker.executionPolicy(forRuntime: .copilotCLI, grants: grants)
        let allowedTools = policy.allowedTools(default: [])

        #expect(allowedTools.contains("shell(gh:search prs *)"))
        #expect(allowedTools.contains("shell(gh:auth status *)"))
        #expect(allowedTools.contains("shell(mkdir:-p *)"))
        #expect(!allowedTools.contains("shell(gh:*)"))
        #expect(policy.permissionGrantsOverride == grants)
    }

    @Test("Broker sanitizes structured approval payloads before provider rendering")
    func brokerSanitizesStructuredApprovalPayloads() throws {
        let payload = PermissionApprovalEventPayload(
            brokerVersion: 999,
            providerID: .claudeCode,
            request: .shell(command: "curl https://example.com", toolName: "Bash"),
            decision: .askUser(message: "approval", grants: [
                .shellCommand(executable: "python3", pattern: "*"),
                .shellCommand(executable: "*", pattern: "*"),
                .providerTool(name: "shell"),
                .providerTool(name: "Write")
            ]),
            grants: [
                .shellCommand(executable: "curl", pattern: "*"),
                .shellCommand(executable: "gh;rm", pattern: "*"),
                .providerTool(name: "Bash"),
                .filePath(path: "/tmp/report.txt", access: "write"),
                .networkPattern(pattern: "https://example.com/*")
            ],
            displayMessage: "approval"
        )

        let encoded = try #require(payload.encodedString())
        let structuredGrants = PermissionBroker.structuredApprovalGrants(from: encoded)

        #expect(structuredGrants == [.shellCommand(executable: "curl", pattern: "*example.com*")])
        #expect(PermissionBroker.providerGrantStrings(for: structuredGrants, runtime: .claudeCode) == [
            "Bash(curl *example.com*)"
        ])

        let executionPolicy = PermissionBroker.executionPolicy(forRuntime: .claudeCode, grants: structuredGrants)
        let allowedTools = executionPolicy.allowedTools(default: [])
        #expect(allowedTools.contains("Bash(curl *example.com*)"))
        #expect(!allowedTools.contains("Bash(python3:*)"))
        #expect(!allowedTools.contains("Write"))
        #expect(!allowedTools.contains("Bash"))
        #expect(!allowedTools.contains("Bash(*)"))
        #expect(Set(executionPolicy.permissionGrantsOverride ?? []) == Set(structuredGrants))
    }

    @Test("Broker approval payload uses typed event payload encoding")
    func brokerApprovalPayloadUsesTypedEventPayloadEncoding() throws {
        let request = PermissionRequest.shell(
            command: "curl https://redcap.stanford.edu/api",
            toolName: "Bash"
        )
        let grants = PermissionBroker.approvalGrants(for: request)
        let payload = PermissionBroker.approvalPayload(
            providerID: .claudeCode,
            request: request,
            reason: "Network check requires approval.",
            grants: grants
        )
        let encoded = TaskEvent.payloadString(
            payload,
            fallback: payload.displayMessage,
            encoder: TaskEventPayloadCodec.makeUnescapedEncoder()
        )
        let decoded = try #require(PermissionApprovalEventPayload.decoded(from: encoded))

        #expect(decoded.providerID == .claudeCode)
        #expect(decoded.request == request)
        #expect(decoded.displayMessage.contains("https://redcap.stanford.edu/api"))
        #expect(PermissionBroker.structuredApprovalGrants(from: encoded) == grants)
    }

    @Test("Broker repairs stale structured shell grants from the typed request")
    func brokerRepairsStaleStructuredShellGrantsFromTypedRequest() throws {
        let request = PermissionRequest.shell(
            command: """
            OUT=.astra/tasks/7A7D0BA8/open_prs.tsv
            mkdir -p "$(dirname "$OUT")"
            gh search prs --author @me --state open
            """,
            toolName: "bash"
        )
        let payload = PermissionApprovalEventPayload(
            brokerVersion: 1,
            providerID: .copilotCLI,
            request: request,
            decision: .askUser(message: "approval", grants: [
                .shellCommand(executable: "dirname", pattern: "*")
            ]),
            grants: [.shellCommand(executable: "dirname", pattern: "*")],
            displayMessage: "Runtime grant: shell(dirname:*)"
        )

        let encoded = try #require(payload.encodedString())

        #expect(PermissionBroker.structuredApprovalGrants(from: encoded) == [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ])
        #expect(PermissionBroker.providerGrantStrings(
            for: PermissionBroker.structuredApprovalGrants(from: encoded),
            runtime: .copilotCLI
        ) == ["shell(gh:search prs *)"])
    }

    @Test("Broker rejects structured grants when request has no scoped approval")
    func brokerRejectsStructuredGrantsWhenRequestHasNoScopedApproval() throws {
        let payload = PermissionApprovalEventPayload(
            brokerVersion: 1,
            providerID: .claudeCode,
            request: .providerNativePrompt(toolName: "WorkspaceAccess", context: "Allow access to these paths?"),
            decision: .askUser(message: "approval", grants: [.providerTool(name: "Write")]),
            grants: [.providerTool(name: "Write")],
            displayMessage: "approval"
        )

        let encoded = try #require(payload.encodedString())

        #expect(PermissionBroker.structuredApprovalGrants(from: encoded).isEmpty)
    }

    @Test("Broker rejects broad legacy grants and parses scoped legacy grants")
    func brokerRejectsBroadLegacyGrantsAndParsesScopedLegacyGrants() {
        #expect(PermissionBroker.legacyApprovalGrants(from: "Runtime grant: Bash(*)").isEmpty)
        #expect(PermissionBroker.legacyApprovalGrants(from: "Runtime grant: shell").isEmpty)
        #expect(PermissionBroker.legacyApprovalGrants(from: #""grant":"Bash""#).isEmpty)
        #expect(PermissionBroker.legacyApprovalGrants(from: "Runtime grant: Bash(curl:*)").isEmpty)
        #expect(PermissionBroker.legacyApprovalGrants(from: "Runtime grant: Bash(curl *example.com*)") == [
            .shellCommand(executable: "curl", pattern: "*example.com*")
        ])
        #expect(PermissionBroker.legacyApprovalGrants(from: #""grant":"write""#) == [
            .providerTool(name: "Write")
        ])
    }

    @Test("Broker maps provider create tools to scoped file write approval")
    func brokerMapsProviderCreateToolsToScopedFileWriteApproval() {
        let path = "/tmp/astra-policy-tests/.astra/tasks/ABC123/index.html"
        let grants = PermissionBroker.approvalGrants(for: .fileWrite(path: path, toolName: "create"))

        #expect(grants.contains(.filePath(path: path, access: "write")))
        #expect(grants.contains(.providerTool(name: "Write")))
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .claudeCode) == ["Write"])
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .copilotCLI) == ["write"])
    }

    @Test("Broker chooses substantive shell executable from setup-heavy scripts")
    func brokerChoosesSubstantiveShellExecutableFromSetupHeavyScripts() {
        let request = PermissionRequest.shell(
            command: """
            set -euo pipefail
            OUT=.astra/tasks/7A7D0BA8/open_prs.tsv
            mkdir -p "$(dirname "$OUT")"
            if ! gh auth status >/dev/null 2>&1; then
              echo "not authenticated"
              exit 0
            fi
            gh search prs --author @me --state open --json repository,title,url
            """,
            toolName: "Bash"
        )

        let grants = PermissionBroker.approvalGrants(for: request)

        #expect(grants == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .claudeCode) == ["Bash(gh search prs *)"])
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .copilotCLI) == ["shell(gh:search prs *)"])
    }

    @Test("Broker ignores shell comments and status output when choosing approval grants")
    func brokerIgnoresShellCommentsAndStatusOutputWhenChoosingApprovalGrants() {
        let request = PermissionRequest.shell(
            command: """
            set -euo pipefail
            # Check gh auth before the query
            if ! gh auth status >/dev/null 2>&1; then
              echo '{"error":"gh not authenticated"}'
              exit 0
            fi
            echo "Fetching open PRs"
            gh search prs "author:@me is:open" --limit 100 --json number,title,url
            """,
            toolName: "bash"
        )

        let grants = PermissionBroker.approvalGrants(for: request)
        let payload = PermissionBroker.approvalPayloadString(
            providerID: .copilotCLI,
            request: request,
            reason: "approval required",
            grants: grants
        )

        #expect(grants == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(PermissionBroker.providerGrantStrings(for: grants, runtime: .copilotCLI) == ["shell(gh:search prs *)"])
        #expect(!payload.contains("shell(#:*)"))
        #expect(!payload.contains("shell(echo:*)"))
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell(#:*)") == nil)
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell(echo:*)") == nil)
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell(gh:*)") == nil)
        #expect(PermissionBroker.resumeMessage(providerID: .copilotCLI, grants: grants).contains("Start shell calls with the approved executable"))
    }

    @Test("Broker ignores line continuations, redirections, and quoted parser text when choosing grants")
    func brokerIgnoresLineContinuationsRedirectionsAndQuotedParserText() {
        let request = PermissionRequest.shell(
            command: """
            mkdir -p .astra/tasks/57096337 && \\
            if ! gh auth status >/dev/null 2>&1; then echo "GH_AUTH_MISSING"; exit 2; fi && \\
            gh search prs --author "@me" --state open --limit 100 --json number,title,state,author,repository,url,createdAt,updatedAt > .astra/tasks/57096337/prs.json && \\
            jq -r '.[] | "repo: \\(.repository) #\\(.number) - \\(.title) | author:\\(.author.login // "unknown")"' .astra/tasks/57096337/prs.json && \\
            gh pr view 123 --repo susom/astra --comments --json number,title,author,state,labels,reviews,files,statusCheckRollup,mergeable,url
            """,
            toolName: "bash"
        )

        let grants = PermissionBroker.approvalGrants(for: request)
        let providerGrants = PermissionBroker.providerGrantStrings(for: grants, runtime: .copilotCLI)
        let resumeMessage = PermissionBroker.resumeMessage(providerID: .copilotCLI, grants: grants)

        #expect(!grants.contains(.shellCommand(executable: "gh", pattern: "search prs *")))
        #expect(grants.contains(.shellCommand(executable: "gh", pattern: "pr view *")))
        #expect(!providerGrants.contains { $0.contains("shell(\\:") })
        #expect(!providerGrants.contains { $0.contains("author:") })
        #expect(!providerGrants.contains { $0.contains("shell(read:") })
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell(\\:*)") == nil)
        #expect(resumeMessage.contains("do not redirect output to a file"))
    }

    @Test("Broker scopes gh approvals by subcommand so read grants do not cover writes")
    func brokerScopesGhApprovalsBySubcommandSoReadGrantsDoNotCoverWrites() {
        let search = PermissionBroker.approvalGrants(for: .shell(
            command: "gh search prs --author @me --state open",
            toolName: "bash"
        ))
        let view = PermissionBroker.approvalGrants(for: .shell(
            command: "gh pr view 123 --json title,url",
            toolName: "bash"
        ))
        let merge = PermissionBroker.approvalGrants(for: .shell(
            command: "gh pr merge 123 --squash --delete-branch",
            toolName: "bash"
        ))

        #expect(search == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(view == [.shellCommand(executable: "gh", pattern: "pr view *")])
        #expect(merge == [.shellCommand(executable: "gh", pattern: "pr merge 123 *")])
        #expect(PermissionBroker.providerGrantStrings(for: view, runtime: .copilotCLI) == ["shell(gh:pr view *)"])
        #expect(PermissionBroker.providerGrantStrings(for: merge, runtime: .copilotCLI) == ["shell(gh:pr merge 123 *)"])
        #expect(view != merge)
    }

    @Test("Broker scopes common shell command families by action tokens")
    func brokerScopesCommonShellCommandFamiliesByActionTokens() {
        let git = PermissionBroker.approvalGrants(for: .shell(
            command: "git status --short",
            toolName: "bash"
        ))
        let gcloud = PermissionBroker.approvalGrants(for: .shell(
            command: "gcloud projects describe upo-nero-phi-su-deid-jsl --format=json",
            toolName: "bash"
        ))
        let bq = PermissionBroker.approvalGrants(for: .shell(
            command: "bq ls --project_id=upo-nero-phi-su-deid-jsl --format=prettyjson",
            toolName: "bash"
        ))

        #expect(git == [.shellCommand(executable: "git", pattern: "status --short *")])
        #expect(gcloud == [.shellCommand(executable: "gcloud", pattern: "projects describe *")])
        #expect(bq == [.shellCommand(executable: "bq", pattern: "ls --project_id=upo-nero-phi-su-deid-jsl *")])
        #expect(PermissionBroker.permissionGrant(fromProviderString: "Bash(git:*)") == nil)
        #expect(PermissionBroker.permissionGrant(fromProviderString: "Bash(git *)") == nil)
        #expect(PermissionBroker.permissionGrant(fromProviderString: "shell(gcloud:*)") == nil)
        #expect(PermissionBroker.providerGrantStrings(for: gcloud, runtime: .claudeCode) == [
            "Bash(gcloud projects describe *)"
        ])
    }

    @Test("Broker scopes commands despite benign redirections but not file writes")
    func brokerScopesCommandsDespiteBenignRedirectionsButNotFileWrites() {
        // The exact prod failure: a read-only command with `2>&1` must still
        // produce a scoped grant instead of an empty (run-killing) result.
        let redirected = PermissionBroker.approvalGrants(for: .shell(
            command: "git -C /repo status 2>&1",
            toolName: "bash"
        ))
        let discarded = PermissionBroker.approvalGrants(for: .shell(
            command: "git log --oneline >/dev/null 2>&1",
            toolName: "bash"
        ))
        // A redirection to a named file is a write that must NOT be folded into
        // a base-command grant — it stays unscopable (empty grants).
        let fileWrite = PermissionBroker.approvalGrants(for: .shell(
            command: "git log > out.log",
            toolName: "bash"
        ))

        #expect(redirected == [.shellCommand(executable: "git", pattern: "status *")])
        #expect(discarded == [.shellCommand(executable: "git", pattern: "log --oneline *")])
        #expect(fileWrite.isEmpty)
    }

    @Test("Shell command risk classifier covers common command families")
    func shellCommandRiskClassifierCoversCommonCommandFamilies() throws {
        let cases: [(String, ShellCommandRiskClassifier.Risk, Bool, PermissionGrant)] = [
            ("git status --short", .read, true, .shellCommand(executable: "git", pattern: "status --short *")),
            ("git push origin main", .mutation, false, .shellCommand(executable: "git", pattern: "push origin main *")),
            ("gh search prs --author @me", .read, true, .shellCommand(executable: "gh", pattern: "search prs *")),
            ("gh pr merge 123 --squash", .mutation, false, .shellCommand(executable: "gh", pattern: "pr merge 123 *")),
            ("gcloud projects describe upo-nero --format=json", .read, true, .shellCommand(executable: "gcloud", pattern: "projects describe *")),
            ("gcloud iam service-accounts add-iam-policy-binding svc", .mutation, false, .shellCommand(executable: "gcloud", pattern: "iam service-accounts add-iam-policy-binding *")),
            ("bq ls --project_id=upo-nero", .read, true, .shellCommand(executable: "bq", pattern: "ls --project_id=upo-nero *")),
            ("bq query 'delete from dataset.table where true'", .mutation, false, .shellCommand(executable: "bq", pattern: "query delete from *")),
            ("aws s3 ls s3://bucket", .read, true, .shellCommand(executable: "aws", pattern: "s3 ls *")),
            ("aws s3 rm s3://bucket/key", .mutation, false, .shellCommand(executable: "aws", pattern: "s3 rm *")),
            ("kubectl get pods", .read, true, .shellCommand(executable: "kubectl", pattern: "get pods *")),
            ("kubectl delete pod api-1", .mutation, false, .shellCommand(executable: "kubectl", pattern: "delete pod api-1 *")),
            ("docker ps", .read, true, .shellCommand(executable: "docker", pattern: "ps *")),
            ("docker run alpine", .mutation, false, .shellCommand(executable: "docker", pattern: "run alpine *")),
            ("curl https://example.com/api", .networkRead, true, .shellCommand(executable: "curl", pattern: "*example.com*")),
            ("curl -f https://example.com/api", .networkRead, true, .shellCommand(executable: "curl", pattern: "*example.com*")),
            ("curl -F file=@report.json https://example.com/api", .mutation, false, .shellCommand(executable: "curl", pattern: "*example.com*")),
            ("curl -X POST https://example.com/api", .mutation, false, .shellCommand(executable: "curl", pattern: "*example.com*")),
            ("ls -la", .fileRead, false, .shellCommand(executable: "ls", pattern: "*")),
            ("cat ~/.zsh_history", .credential, false, .shellCommand(executable: "cat", pattern: "~/.zsh_history *")),
            ("python3 script.py", .scriptExecution, false, .shellCommand(executable: "python3", pattern: "script.py *"))
        ]

        for (command, expectedRisk, expectedReuse, expectedGrant) in cases {
            let assessment = try #require(ShellCommandRiskClassifier.assessment(forShellSegment: command))
            #expect(assessment.risk == expectedRisk)
            #expect(assessment.allowsTaskScopedReuse == expectedReuse)
            #expect(ShellCommandRiskClassifier.approvalGrant(forShellSegment: command) == expectedGrant)
        }
    }

    @Test("Shell command approvals touching privacy-sensitive machine paths are not task-reusable")
    func shellCommandApprovalsTouchingPrivacySensitiveMachinePathsAreNotTaskReusable() throws {
        let commands = [
            "git -C ~/Pictures status --short",
            "git -C /Applications status --short",
            "defaults read ~/Library/Photos",
            "git -C /tmp/Photos.photoslibrary status --short",
            "git -C /tmp/Music.musiclibrary status --short",
            "git -C /tmp/Preview.app status --short"
        ]

        for command in commands {
            let assessment = try #require(ShellCommandRiskClassifier.assessment(forShellSegment: command))
            #expect(assessment.risk == .read)
            #expect(assessment.allowsTaskScopedReuse == false)
        }
    }

    @Test("Shell command approvals only treat media roots as sensitive at path boundaries")
    func shellCommandApprovalsOnlyTreatMediaRootsAsSensitiveAtPathBoundaries() throws {
        let reusableCommands = [
            "git -C /tmp/music-output status --short",
            "git -C /tmp/project/picturesque status --short",
            "git -C /tmp/src/music status --short"
        ]

        for command in reusableCommands {
            let assessment = try #require(ShellCommandRiskClassifier.assessment(forShellSegment: command))
            #expect(assessment.risk == .read)
            #expect(assessment.allowsTaskScopedReuse)
        }
    }

    @Test("Shell command risk classifier refuses unsupported shell constructs")
    func shellCommandRiskClassifierRefusesUnsupportedShellConstructs() {
        let unsupported = [
            "gh search prs --author <(cat ~/.ssh/id_ed25519)",
            "bq query $'select * from dataset.table'",
            "cat <<EOF\nsecret\nEOF",
            "curl https://example.com <<< token",
            "gh api < ~/.ssh/id_ed25519",
            "gh api > response.json",
            "git status `cat ~/.ssh/id_ed25519`",
            "git status \\\n--short"
        ]

        for command in unsupported {
            #expect(ShellCommandRiskClassifier.assessment(forShellSegment: command) == nil)
            #expect(ShellCommandRiskClassifier.approvalGrant(forShellSegment: command) == nil)
        }
    }

    @Test("Wildcard pattern matcher caches compiled regexes")
    func wildcardPatternMatcherCachesCompiledRegexes() {
        let matcher = WildcardPatternMatcher()

        #expect(matcher.matches("gh search prs", pattern: "gh search *"))
        #expect(matcher.compiledPatternCount == 1)
        #expect(matcher.matches("gh search issues", pattern: "gh search *"))
        #expect(matcher.compiledPatternCount == 1)
        #expect(!matcher.matches("git push origin main", pattern: "gh search *"))
        #expect(matcher.compiledPatternCount == 1)
        #expect(matcher.matches("git status", pattern: "git stat?s"))
        #expect(matcher.compiledPatternCount == 2)
    }

    @Test("Wildcard pattern matcher bounds compiled regex cache")
    func wildcardPatternMatcherBoundsCompiledRegexCache() {
        let matcher = WildcardPatternMatcher()

        for index in 0..<300 {
            #expect(matcher.matches("value-\(index)", pattern: "value-\(index)"))
        }
        #expect(matcher.compiledPatternCount <= 256)
    }

    @Test("Task scoped approval grants exclude risky shell commands")
    func taskScopedApprovalGrantsExcludeRiskyShellCommands() {
        let reusable = PermissionBroker.taskScopedApprovalGrants(for: [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ])
        let risky = PermissionBroker.taskScopedApprovalGrants(for: [
            .shellCommand(executable: "gh", pattern: "pr merge *")
        ])
        let mixed = PermissionBroker.taskScopedApprovalGrants(for: [
            .shellCommand(executable: "gh", pattern: "search prs *"),
            .shellCommand(executable: "cat", pattern: "~/.zsh_history *")
        ])

        #expect(reusable == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(risky.isEmpty)
        #expect(mixed.isEmpty)
    }

    @Test("Broker refuses unscoped provider native prompts")
    func brokerRefusesUnscopedProviderNativePrompts() {
        let request = PermissionBroker.providerNativePromptRequest(
            toolName: "WorkspaceAccess",
            context: "Allow access to these paths? (y/n)"
        )

        #expect(PermissionBroker.approvalGrants(for: request).isEmpty)
        #expect(PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: request,
            reason: "approval required",
            grants: PermissionBroker.approvalGrants(for: request)
        ).contains("Runtime grant:") == false)
    }

    @Test("Future provider adapter default mapping stays scoped")
    func futureProviderAdapterDefaultMappingStaysScoped() {
        let adapter = FutureProviderPolicyAdapterFixture()
        let grants: [PermissionGrant] = [
            .shellCommand(executable: "node", pattern: "*"),
            .filePath(path: "/tmp/report.txt", access: "write"),
            .networkPattern(pattern: "https://example.com/*"),
            .providerTool(name: "Read")
        ]

        #expect(adapter.providerGrantStrings(for: grants) == ["shell(node:*)", "Read"])
    }

    @Test("Brokered provider adapters keep scoped shell grants visible")
    func brokeredProviderAdaptersKeepScopedShellGrantsVisible() {
        let grants: [PermissionGrant] = [
            .shellCommand(executable: "gh", pattern: "pr list *")
        ]
        let runtimes: [AgentRuntimeID] = [
            .antigravityCLI,
            .codexCLI,
            .cursorCLI,
            .openCodeCLI
        ]

        for runtime in runtimes {
            #expect(
                PermissionBroker.providerGrantStrings(for: grants, runtime: runtime) == ["shell(gh:pr list *)"],
                "\(runtime.rawValue) should keep scoped shell approvals visible to ASTRA's broker"
            )
            #expect(
                PermissionBroker.providerRuntimeGrantStrings(for: grants, runtime: runtime).contains("shell(gh:pr list *)"),
                "\(runtime.rawValue) should replay scoped shell approvals on runtime retries"
            )
        }
    }

    @Test("Launch execution policy uses rendered provider tools")
    func launchExecutionPolicyUsesRenderedProviderTools() {
        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: adapter.supportedFeatures,
                requestedAllowedTools: ["Bash", "Write"]
            )
        )

        let launchPolicy = AgentRuntimeExecutionPolicy.default.applyingProviderRender(render)

        #expect(launchPolicy.allowedTools(default: ["Bash", "Write"]) == ["Glob", "Grep", "Read"])
        #expect(launchPolicy.permissionPolicy(default: .autonomous) == .restricted)
    }

    @Test("Review render does not allow local CLI tools without approval")
    func reviewRenderDoesNotAllowLocalCLIToolsWithoutApproval() {
        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(!claudeRender.allowedTools.contains("Bash(gh:*)"))
        #expect(!claudeRender.allowedTools.contains("Bash(gh *)"))

        let copilot = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: """
            --allow-tool
            --output-format
            """)
        ))
        let copilotRender = copilot.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(!copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(!copilotRender.generatedConfigPreview.contains("shell(gh:*)"))
    }

    @Test("Build render grants enabled local CLI tools")
    func buildRenderGrantsEnabledLocalCLITools() {
        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: .preset(.build),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                localToolCommands: ["astra-browser page"]
            )
        )
        #expect(claudeRender.allowedTools.contains("Bash(astra-browser *)"))

        let copilot = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: """
            --allow-tool
            --output-format
            """)
        ))
        let copilotRender = copilot.render(
            policy: .preset(.build),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(copilotRender.generatedConfigPreview.contains("shell(gh:*)"))
    }

    @Test("Unsupported credential redaction is a blocked diagnostic")
    func unsupportedCredentialRedactionBlocksRender() {
        let adapter = CopilotPolicyAdapter(capabilities: .conservative)
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: adapter.supportedFeatures,
                credentialLabels: ["API_TOKEN"]
            )
        )

        #expect(render.diagnostics.contains {
            $0.severity == .blocked && $0.id == "copilot_cli.secret-redaction-unsupported"
        })
    }
}

@Suite("Task Policy Store")
@MainActor
struct TaskPolicyStoreTests {
    @Test("Resolution order prefers task override over workspace and global defaults")
    func resolutionOrder() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Policy Workspace", primaryPath: "/tmp/policy-workspace")
        let task = AgentTask(title: "Policy", goal: "Check policy", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        AgentPolicyDefaults.setWorkspaceLevel(.build, for: workspace)
        defer {
            AgentPolicyDefaults.setWorkspaceLevel(nil, for: workspace)
            AgentPolicyDefaults.resetCustomPolicy(for: workspace)
        }

        let workspaceResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .restricted,
            executionPolicy: .default
        )
        #expect(workspaceResolution.level == .custom)
        #expect(workspaceResolution.scope == .workspaceDefault)
        #expect(workspaceResolution.policy.level == .custom)
        #expect(workspaceResolution.policy.allowedTools.contains("Bash"))
        #expect(workspaceResolution.policy.allowedShellPatterns.contains("swift:*"))

        TaskPolicyStore.recordSelection(level: .locked, task: task, modelContext: context, source: "test")
        try context.save()

        let taskResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .restricted,
            executionPolicy: .default
        )
        #expect(taskResolution.level == .locked)
        #expect(taskResolution.scope == .taskOverride)
    }

    @Test("One-run permission approval preserves policy level and scopes approved tools")
    func oneRunApprovalScopesApprovedTools() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Check policy")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        TaskPolicyStore.recordSelection(level: .locked, task: task, modelContext: context, source: "test")
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: "/tmp/policy-workspace",
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .approvedRuntimePermission(runtime: .claudeCode, allowedTools: ["Write"]),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.policyLevel == .locked)
        #expect(manifest.policyScope == .oneRunEscalation)
        #expect(manifest.providerRender.permissionMode == .restricted)
        #expect(manifest.providerRender.allowedTools.contains("Write"))
        #expect(!manifest.providerRender.usesBroadProviderPermissions)
    }

    @Test("Copilot runtime approval stays scoped to one-run provider permissions")
    func copilotRuntimeApprovalStaysScoped() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Fetch Jira issues", runtime: .copilotCLI)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let executionPolicy = PermissionBroker.executionPolicy(
            forRuntime: .copilotCLI,
            grants: [.shellCommand(executable: "curl", pattern: "*stanfordmed.atlassian.net*")]
        )
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: "claude-sonnet-4.6",
            workspacePath: "/tmp/policy-workspace",
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: executionPolicy,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            providerCapabilities: AgentRuntimePolicyCapabilities(
                supportsOutputFormatJSON: true,
                supportsStreamingFlag: true,
                supportsNoAskUser: true,
                supportsSilent: true,
                supportsSecretEnvVars: true,
                supportsAllowAll: true,
                supportsAllowAllTools: true,
                supportsAllowAllPaths: true,
                supportsAllowAllURLs: true,
                requiresAllowAllToolsForPrompt: false
            ),
            modelContext: context
        )

        #expect(manifest.policyLevel == .review)
        #expect(manifest.policyScope == .oneRunEscalation)
        #expect(manifest.providerRender.permissionMode == .restricted)
        #expect(!manifest.providerRender.usesBroadProviderPermissions)
        #expect(manifest.approvalGrants == [.shellCommand(executable: "curl", pattern: "*stanfordmed.atlassian.net*")])
    }

    @Test("Custom workspace policy is resolved into the preflight manifest")
    func customWorkspacePolicyResolvesIntoPreflightManifest() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Custom Policy Workspace", primaryPath: "/tmp/custom-policy-workspace")
        let task = AgentTask(title: "Policy", goal: "Check custom policy", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let customPolicy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash"],
            askFirstTools: ["Write"],
            allowedShellPatterns: ["git:*"],
            deniedShellPatterns: ["rm:*"]
        )
        AgentPolicyDefaults.setWorkspaceLevel(.custom, for: workspace)
        AgentPolicyDefaults.setCustomPolicy(customPolicy, for: workspace)
        defer {
            AgentPolicyDefaults.setWorkspaceLevel(nil, for: workspace)
            AgentPolicyDefaults.resetCustomPolicy(for: workspace)
        }

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.policyLevel == .custom)
        #expect(manifest.policyScope == .workspaceDefault)
        #expect(manifest.providerRender.allowedTools.contains("Bash"))
        #expect(manifest.providerRender.deniedShellPatterns.contains("rm:*"))
        #expect(manifest.providerRender.allowedShellPatterns.contains("git:*"))
    }
}

// Serialized: several sandbox-tier tests mutate `UserDefaults.standard` sandbox
// keys (with save/restore), so they must not run concurrently with each other or
// with other suites reading the same keys.
@Suite("Run Permission Manifest", .serialized)
@MainActor
struct RunPermissionManifestTests {
    @Test("Preflight manifest persists policy render without environment values")
    func preflightManifestPersistsWithoutEnvValues() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Manifest", primaryPath: "/tmp/manifest-workspace")
        let task = AgentTask(title: "Manifest", goal: "Use the Env Skill to persist manifest", workspace: workspace)
        let skill = Skill(
            name: "Env Skill",
            allowedTools: ["Read"],
            environmentVariables: ["PLAIN_ENV": "value-that-must-not-be-logged"]
        )
        task.skills = [skill]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(skill)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        let manifestEvent = events.first { $0.type == AgentPolicyManifestService.preflightEventType }

        #expect(manifest.policyLevel == .review)
        #expect(manifest.environmentKeyNames == ["PLAIN_ENV"])
        #expect(manifestEvent != nil)
        #expect(manifestEvent?.payload.contains("PLAIN_ENV") == true)
        #expect(manifestEvent?.payload.contains("value-that-must-not-be-logged") == false)
    }

    @Test("Preflight manifest declares the OS sandbox tier for wrapped runtimes")
    func preflightManifestDeclaresOSSandboxTier() throws {
        // Pin the relevant sandbox defaults so the assertion is deterministic
        // regardless of any developer's stored preference.
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let layerKey = AppStorageKeys.sandboxLayerNativeProviders
        let previousEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        let previousLayer = UserDefaults.standard.object(forKey: layerKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: enforcementKey)
        UserDefaults.standard.set(false, forKey: layerKey)
        defer {
            if let previousEnforcement {
                UserDefaults.standard.set(previousEnforcement, forKey: enforcementKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enforcementKey)
            }
            if let previousLayer {
                UserDefaults.standard.set(previousLayer, forKey: layerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layerKey)
            }
        }

        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Sandbox Tier", primaryPath: "/tmp/sandbox-tier-workspace")
        context.insert(workspace)

        // Claude Code is wrapped by ASTRA's Seatbelt -> OS sandbox tier declared.
        let claudeTask = AgentTask(title: "Claude", goal: "Do work", workspace: workspace)
        let claudeRun = TaskRun(task: claudeTask)
        context.insert(claudeTask)
        context.insert(claudeRun)
        let claude = AgentPolicyManifestService.recordPreflightManifest(
            task: claudeTask,
            run: claudeRun,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        #expect(claude.providerRender.enforcementTiers.contains(.osSandboxed))

        // Codex self-sandboxes and is not layered by default -> no OS sandbox tier.
        let codexTask = AgentTask(title: "Codex", goal: "Do work", workspace: workspace)
        let codexRun = TaskRun(task: codexTask)
        context.insert(codexTask)
        context.insert(codexRun)
        let codex = AgentPolicyManifestService.recordPreflightManifest(
            task: codexTask,
            run: codexRun,
            runtime: .codexCLI,
            model: "gpt-5.5",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        #expect(!codex.providerRender.enforcementTiers.contains(.osSandboxed))
    }

    @Test("Preflight manifest layers the OS sandbox tier over a self-sandboxing provider when opted in")
    func preflightManifestLayersOSSandboxTierWhenOptedIn() throws {
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let layerKey = AppStorageKeys.sandboxLayerNativeProviders
        let previousEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        let previousLayer = UserDefaults.standard.object(forKey: layerKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: enforcementKey)
        UserDefaults.standard.set(true, forKey: layerKey) // opt in to layering
        defer {
            if let previousEnforcement {
                UserDefaults.standard.set(previousEnforcement, forKey: enforcementKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enforcementKey)
            }
            if let previousLayer {
                UserDefaults.standard.set(previousLayer, forKey: layerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: layerKey)
            }
        }

        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Layered Tier", primaryPath: "/tmp/layered-tier-workspace")
        context.insert(workspace)

        let codexTask = AgentTask(title: "Codex", goal: "Do work", workspace: workspace)
        let codexRun = TaskRun(task: codexTask)
        context.insert(codexTask)
        context.insert(codexRun)
        let codex = AgentPolicyManifestService.recordPreflightManifest(
            task: codexTask,
            run: codexRun,
            runtime: .codexCLI,
            model: "gpt-5.5",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        // With layering on, Codex is now wrapped by ASTRA's Seatbelt too.
        #expect(codex.providerRender.enforcementTiers.contains(.osSandboxed))
    }

    @Test("Preflight manifest omits the OS sandbox tier when the sandbox would not actually apply")
    func preflightManifestOmitsTierWhenSandboxWontApply() throws {
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let previousEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: enforcementKey)
        defer {
            if let previousEnforcement {
                UserDefaults.standard.set(previousEnforcement, forKey: enforcementKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enforcementKey)
            }
        }

        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        // An over-broad workspace ("/") makes the sandbox refuse to apply; under
        // best-effort that's a silent fallback to unconfined, so the manifest must
        // NOT claim "OS Sandboxed" (otherwise display diverges from launch).
        let workspace = Workspace(name: "Root Workspace", primaryPath: "/")
        context.insert(workspace)
        let task = AgentTask(title: "Claude", goal: "Do work", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        #expect(!manifest.providerRender.enforcementTiers.contains(.osSandboxed))
    }

    @Test("Disabled enforcement removes the OS sandbox tier even under an autonomous override")
    func preflightManifestTierRespectsDisabledEnforcementUnderOverride() throws {
        // The sandbox is OFF. Even with an execution-policy override that escalates
        // the permission policy to autonomous, the manifest must NOT manufacture an
        // "OS Sandboxed" tier — the user-level kill switch wins. This exercises the
        // override path (`manifestExecutionPolicy.permissionPolicyOverride ??
        // permissionPolicy`) while asserting a property that would actually break
        // if off-enforcement weren't honored (the binary tier is unaffected by the
        // best-effort/strict distinction, so off-vs-on is what's observable here).
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let previousEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.off.rawValue, forKey: enforcementKey)
        defer {
            if let previousEnforcement {
                UserDefaults.standard.set(previousEnforcement, forKey: enforcementKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enforcementKey)
            }
        }

        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Override Tier", primaryPath: "/tmp/override-tier-workspace")
        context.insert(workspace)
        let task = AgentTask(title: "Claude", goal: "Do work", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let overridePolicy = AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: .autonomous,
            allowedToolsOverride: nil,
            permissionGrantsOverride: nil
        )
        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: overridePolicy,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        #expect(!manifest.providerRender.enforcementTiers.contains(.osSandboxed))
    }

    @Test("Preflight manifest persists Copilot runtime support tools separately")
    func preflightManifestPersistsCopilotRuntimeSupportToolsSeparately() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Support Tools", primaryPath: "/tmp/support-tools-workspace")
        let task = AgentTask(title: "Support Tools", goal: "Who are you?", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: "gpt-5",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            providerCapabilities: AgentRuntimePolicyCapabilities(
                copilotCLI: CopilotCLICapabilities(helpText: """
                --allow-tool
                --output-format
                --stream
                --no-ask-user
                """)
            ),
            modelContext: context
        )
        try context.save()

        let supportToolNames = manifest.providerRender.runtimeSupportTools.map(\.name)
        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        let manifestEvent = events.first { $0.type == AgentPolicyManifestService.preflightEventType }

        #expect(supportToolNames == ["fetch_copilot_cli_documentation", "report_intent"])
        #expect(!manifest.providerRender.allowedTools.contains("fetch_copilot_cli_documentation"))
        #expect(!manifest.providerRender.allowedTools.contains("report_intent"))
        #expect(manifest.providerRender.cliArgumentsSummary.contains("fetch_copilot_cli_documentation"))
        #expect(manifest.providerRender.cliArgumentsSummary.contains("report_intent"))
        #expect(manifest.providerRender.generatedConfigPreview.contains("fetch_copilot_cli_documentation"))
        #expect(manifest.providerRender.generatedConfigPreview.contains("report_intent"))
        #expect(manifest.approvalsGranted.isEmpty)
        #expect(manifest.approvalGrants.isEmpty)
        #expect(!manifest.providerRender.allowedShellPatterns.contains(#"echo "$ASTRA_CONNECTORS" | head -50"#))
        #expect(manifestEvent?.payload.contains("\"runtimeSupportTools\"") == true)
        #expect(manifestEvent?.payload.contains("\"fetch_copilot_cli_documentation\"") == true)
    }

    @Test("Docker preflight manifest exposes workspace executor and projected credential state")
    func dockerPreflightManifestExposesWorkspaceExecutorAndProjectedCredentialState() throws {
        for runtime in [AgentRuntimeID.claudeCode, .copilotCLI, .codexCLI] {
            let container = try makeAgentPolicyContainer()
            let context = container.mainContext
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("astra-docker-manifest-\(runtime.rawValue)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let package = PluginPackage(
                id: "host-control-plane",
                name: "Host Control Plane",
                icon: "server.rack",
                description: "Host capability server",
                author: "Tests",
                category: "Tests",
                tags: [],
                version: "1.0.0",
                skills: [],
                connectors: [],
                localTools: [],
                mcpServers: [
                    PluginMCPServer(
                        id: "github",
                        displayName: "GitHub MCP",
                        transport: .stdio,
                        command: "github-mcp-server",
                        allowedTools: ["pull_requests.read"],
                        trustLevel: .high
                    )
                ],
                templates: [],
                governance: .builtInApproved(riskLevel: .high)
            )
            let workspace = Workspace(name: "Docker Manifest", primaryPath: root.path)
            workspace.enabledCapabilityIDs = [package.id]
            let task = AgentTask(
                title: "Docker",
                goal: "Check dbt inside Docker",
                workspace: workspace,
                model: "test-model",
                runtime: runtime
            )
            let shellSkill = Skill(name: "Shell", allowedTools: ["Read", "Bash"])
            shellSkill.workspace = workspace
            task.skills = [shellSkill]
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
                id: "image:starr",
                kind: .dockerImage,
                displayName: "starr Image",
                image: "astra-starr-data-lake:latest",
                credentialProjections: [
                    ExecutionEnvironmentCredentialProjection.gcpADC(
                        hostPath: root.appendingPathComponent(".config/gcloud", isDirectory: true).path
                    )
                ]
            ))
            let run = TaskRun(task: task)
            context.insert(workspace)
            context.insert(shellSkill)
            context.insert(task)
            context.insert(run)

            let manifest = AgentPolicyManifestService.recordPreflightManifest(
                task: task,
                run: run,
                runtime: runtime,
                model: "test-model",
                workspacePath: workspace.primaryPath,
                phase: "test",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                capabilityPackages: [package],
                modelContext: context
            )

            #expect(manifest.environmentKeyNames.contains("CLOUDSDK_CONFIG"))
            #expect(manifest.environmentKeyNames.contains("GOOGLE_APPLICATION_CREDENTIALS"))
            #expect(manifest.credentialLabels.contains("docker:GCP Application Default Credentials:ro:/root/.config/gcloud"))
            #expect(manifest.mcpServers.contains { server in
                server.packageID == "astra-builtin"
                    && server.id == DockerWorkspaceMCPProjection.serverID
                    && server.allowedTools == DockerWorkspaceMCPProjection.toolNames
            })
            #expect(manifest.mcpServers.contains { server in
                server.packageID == "astra-builtin"
                    && server.id == HostControlPlaneMCPProjection.serverID
                    && server.allowedTools == HostControlPlaneMCPProjection.toolNames
            })
            #expect(manifest.mcpServers.contains { server in
                server.packageID == package.id
                    && server.id == "github"
                    && server.allowedTools == ["pull_requests.read"]
            })
            #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
                descriptor.name == DockerWorkspaceMCPProjection.providerToolPermission
                    && descriptor.allowedInputKeys.contains("command")
            })
            #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
                descriptor.name == DockerWorkspaceMCPProjection.providerToolPermission(for: "workspace_job_start")
                    && descriptor.allowedInputKeys.contains("command")
                    && descriptor.allowedInputKeys.contains("progress_probe")
            })
            #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
                descriptor.name == DockerWorkspaceMCPProjection.providerToolPermission(for: "workspace_job_status")
                    && descriptor.allowedInputKeys == ["job_id"]
            })
            #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
                descriptor.name == HostControlPlaneMCPProjection.providerToolPermission(for: "gcloud")
                    && descriptor.allowedInputKeys == ["arguments", "timeout_seconds"]
            })
            #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
                descriptor.name == HostControlPlaneMCPProjection.providerToolPermission(for: "jira")
                    && descriptor.allowedInputKeys.contains("operation")
                    && descriptor.allowedInputKeys.contains("issue_key")
                    && descriptor.allowedInputKeys.contains("jql")
                    && descriptor.allowedInputKeys.contains("next_page_token")
                    && !descriptor.allowedInputKeys.contains("method")
                    && !descriptor.allowedInputKeys.contains("path")
                    && !descriptor.allowedInputKeys.contains("body")
            })
            #expect(manifest.providerRender.diagnostics.contains { diagnostic in
                diagnostic.id == "container.host-control-plane-routing"
                    && diagnostic.message.contains("Host services such as GitHub, Jira, Google Cloud, SSH, browser, and Keychain")
                    && diagnostic.remediation?.contains("Enable or repair the relevant capability") == true
            })
            #expect(!manifest.providerRender.allowedTools.contains { tool in
                let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return lower == "bash" || lower == "shell" || lower.hasPrefix("bash(") || lower.hasPrefix("shell(")
            })
        }
    }

    @Test("Host GitHub capability routes through ASTRA host-control MCP instead of native Bash")
    func hostGitHubCapabilityRoutesThroughAstraHostControlMCPInsteadOfNativeBash() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-host-github-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Host GitHub", primaryPath: root.path)
        workspace.enabledCapabilityIDs = [package.id]
        let pluginSkill = try #require(package.skills.first)
        let githubSkill = Skill(
            name: pluginSkill.name,
            skillDescription: pluginSkill.description,
            allowedTools: pluginSkill.allowedTools,
            disallowedTools: pluginSkill.disallowedTools,
            behaviorInstructions: pluginSkill.behaviorInstructions
        )
        githubSkill.workspace = workspace
        let task = AgentTask(
            title: "Review PR",
            goal: "Use GitHub to inspect pull requests and checks",
            workspace: workspace,
            model: "test-model",
            runtime: .claudeCode
        )
        task.skills = [githubSkill]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(githubSkill)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "test-model",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            modelContext: context
        )

        #expect(manifest.mcpServers.contains { server in
            server.packageID == "astra-builtin"
                && server.id == HostControlPlaneMCPProjection.serverID
                && server.allowedTools == ["github"]
        })
        #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
            descriptor.name == HostControlPlaneMCPProjection.providerToolPermission(for: "github")
                && descriptor.allowedInputKeys == ["arguments", "timeout_seconds"]
        })
        #expect(!manifest.providerRender.allowedTools.contains { tool in
            let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "bash" || lower == "shell" || lower.hasPrefix("bash(") || lower.hasPrefix("shell(")
        })
        #expect(manifest.providerRender.deniedTools.contains("Bash"))
    }

    @Test("Custom GitHub text does not enable host-control GitHub")
    func customGitHubTextDoesNotEnableHostControlGitHub() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Markdown", primaryPath: "/tmp/github-flavored-markdown")
        let skill = Skill(
            name: "GitHub-flavored Markdown",
            skillDescription: "Format Markdown tables for README files",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use GitHub-flavored Markdown conventions when formatting text."
        )
        skill.workspace = workspace
        let task = AgentTask(
            title: "Format docs",
            goal: "Format this README table using GitHub-flavored Markdown",
            workspace: workspace,
            model: "test-model",
            runtime: .claudeCode
        )
        task.skills = [skill]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(skill)
        context.insert(task)
        context.insert(run)

        let tools = HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: DockerExecutionPlanner.resolveEnvironment(for: task),
            contextText: task.goal
        )
        #expect(tools.isEmpty)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(!manifest.mcpServers.contains { $0.id == HostControlPlaneMCPProjection.serverID })
        #expect(!manifest.providerRender.runtimeSupportTools.contains {
            $0.name == HostControlPlaneMCPProjection.providerToolPermission(for: "github")
        })
    }

    @Test("Preflight manifest allows exact connector manifest shell probe when connectors are projected")
    func preflightManifestAllowsExactConnectorManifestShellProbeWhenConnectorsAreProjected() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira Connector Probe", primaryPath: "/tmp/jira-connector-probe")
        let connector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS"]
        connector.configValues = ["https://stanfordmed.atlassian.net", "SS"]
        let task = AgentTask(title: "Review Jira issues", goal: "List open Jira issues", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(run)
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: "gpt-5",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.environmentKeyNames.contains("ASTRA_CONNECTORS"))
        #expect(manifest.providerRender.allowedShellPatterns.contains(#"echo "$ASTRA_CONNECTORS" | head -50"#))
        #expect(manifest.providerRender.allowedShellPatterns.contains(#"printf '%s\n' "$ASTRA_CONNECTORS" | head -50"#))
        #expect(!manifest.providerRender.allowedShellPatterns.contains("head -*"))
        #expect(!manifest.providerRender.allowedShellPatterns.contains("echo:*"))
    }

    @Test("Preflight manifest includes task folder as runtime path when workspace path is code root")
    func preflightManifestIncludesTaskFolderAsRuntimePathWhenWorkspacePathIsCodeRoot() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let durableWorkspace = "/tmp/astra-dev-workspaces/artana"
        let codeRoot = "/tmp/astra-code-root"
        let workspace = Workspace(name: "Artana", primaryPath: durableWorkspace)
        workspace.additionalPaths = [codeRoot]
        let task = AgentTask(
            title: "OpenCode state read",
            goal: "Read task state then answer",
            workspace: workspace,
            model: "opencode/big-pickle",
            runtime: .openCodeCLI
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .openCodeCLI,
            model: "opencode/big-pickle",
            workspacePath: codeRoot,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.workspacePath == codeRoot)
        #expect(manifest.additionalPaths.contains(TaskWorkspaceAccess(task: task).taskFolder))
        #expect(manifest.additionalPaths.contains(durableWorkspace))
    }

    @Test("Old manifest JSON without runtime support tools decodes")
    func oldManifestJSONWithoutRuntimeSupportToolsDecodes() throws {
        let render = ProviderPolicyRender(
            providerID: .copilotCLI,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: .restricted,
            allowedTools: ["read"],
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools,
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "test",
            providerID: .copilotCLI,
            providerVersion: nil,
            model: "gpt-5",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: render,
            workspacePath: "/tmp/support-tools-workspace",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )
        let encoded = try JSONEncoder().encode(manifest)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var providerRender = try #require(object["providerRender"] as? [String: Any])
        providerRender.removeValue(forKey: "runtimeSupportTools")
        object["providerRender"] = providerRender
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RunPermissionManifest.self, from: oldData)

        #expect(decoded.providerRender.runtimeSupportTools.isEmpty)
        #expect(decoded.providerRender.allowedTools == ["read"])
    }

    @MainActor
    @Test("Post-run summary records provider sandbox write denials")
    func postRunSummaryRecordsProviderSandboxWriteDenials() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Sandbox Summary", primaryPath: "/Users/alvaro/Documents/Code/monorepo")
        let task = AgentTask(title: "Sandbox Summary", goal: "Write outside workspace", workspace: workspace)
        task.runtimeID = AgentRuntimeID.cursorCLI.rawValue
        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.completedAt = Date()
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        _ = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .cursorCLI,
            model: "auto",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        context.insert(TaskEvent(
            task: task,
            type: "agent.thinking",
            payload: "A file write was rejected, likely because the target path sits outside the workspace sandbox.",
            run: run
        ))
        context.insert(TaskEvent(
            task: task,
            type: "agent.response",
            payload: "I tried to create `/Users/alvaro/Documents/Code/flujo/flujo/test.sh`, but writes to that path were blocked from this session — it’s outside your open Cursor workspace roots.",
            run: run
        ))
        try context.save()

        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: context)
        try context.save()

        let summaryEvent = try #require(task.events.last { $0.type == AgentPolicyManifestService.summaryEventType })
        let object = try #require(JSONSerialization.jsonObject(with: Data(summaryEvent.payload.utf8)) as? [String: Any])
        let deniedActions = try #require(object["deniedActions"] as? [String])

        #expect(object["deniedCount"] as? Int == 1)
        #expect(deniedActions.contains { $0.contains("provider_sandbox_blocked_write") })
        #expect(deniedActions.contains { $0.contains("/Users/alvaro/Documents/Code/flujo/flujo/test.sh") })
    }

    @MainActor
    @Test("Preflight manifest declares Git credential projection for network Git intent")
    func preflightManifestDeclaresGitCredentialProjection() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Git Projection", primaryPath: "/tmp/astra-git-projection")
        let task = AgentTask(title: "Git Projection", goal: "Prepare branch", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "auto",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .autonomous,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            contextText: "ok lets pull the latest code from main, then create a new branch",
            modelContext: context
        )

        #expect(manifest.credentialLabels.contains("git:credential-context:read-only"))
        #expect(manifest.providerRender.diagnostics.contains { $0.id == "git.credential-projection" })
    }

    @MainActor
    @Test("Copilot Git credential path access is represented in preflight render evidence")
    func copilotGitCredentialPathAccessIsRepresentedInPreflightRenderEvidence() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Copilot Git Projection", primaryPath: "/tmp/astra-copilot-git-projection")
        let task = AgentTask(title: "Git Projection", goal: "Pull latest from GitHub", workspace: workspace, runtime: .copilotCLI)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: "gpt-5",
            workspacePath: workspace.primaryPath,
            phase: "run",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            providerCapabilities: AgentRuntimePolicyCapabilities(copilotCLI: CopilotCLICapabilities(helpText: """
            --allow-tool
            --allow-all-paths
            --output-format
            --stream
            --no-ask-user
            """)),
            contextText: "git pull origin main",
            modelContext: context
        )

        #expect(manifest.credentialLabels.contains("git:credential-context:read-only"))
        #expect(manifest.providerRender.cliArgumentsSummary.contains("--allow-all-paths"))
        #expect(manifest.providerRender.generatedConfigPreview.contains("--allow-all-paths"))
        #expect(manifest.providerRender.diagnostics.contains { $0.id == "git.credential-projection" })
    }

    @MainActor
    @Test("Post-run summary records OS sandbox read denials")
    func postRunSummaryRecordsOSSandboxReadDenials() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "OS Sandbox Summary", primaryPath: "/Users/alvaro/Documents/Code/monorepo")
        let task = AgentTask(title: "OS Sandbox Summary", goal: "Pull main", workspace: workspace)
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "os_sandbox_file_read_denied"
        run.completedAt = Date()
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        _ = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "auto",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .autonomous,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            contextText: "pull the latest code from main",
            modelContext: context
        )
        context.insert(TaskEvent(
            task: task,
            type: "tool.result",
            payload: "Exit code 128\nfatal: unable to access '/Users/alvaro1/.gitconfig': Operation not permitted",
            run: run
        ))
        try context.save()

        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: context)
        try context.save()

        let summaryEvent = try #require(task.events.last { $0.type == AgentPolicyManifestService.summaryEventType })
        let object = try #require(JSONSerialization.jsonObject(with: Data(summaryEvent.payload.utf8)) as? [String: Any])
        let deniedActions = try #require(object["deniedActions"] as? [String])

        #expect(object["deniedCount"] as? Int == 1)
        #expect(deniedActions.contains { $0.contains("os_sandbox_blocked_read") })
        #expect(deniedActions.contains { $0.contains("/Users/alvaro1/.gitconfig") })
    }

    @MainActor
    @Test("Post-run summary ignores nonfatal Git sandbox warnings in successful output")
    func postRunSummaryIgnoresNonfatalGitSandboxWarnings() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Git Sandbox", primaryPath: "/Users/alvaro1/Documents/Coral/Code/starr-data-lake")
        let task = AgentTask(title: "Git Sandbox", goal: "Pull latest", workspace: workspace)
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let run = TaskRun(task: task)
        run.status = .completed
        run.completedAt = Date()
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        _ = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "auto",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .autonomous,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            contextText: "git fetch origin && git pull origin main",
            modelContext: context
        )
        context.insert(TaskEvent(
            task: task,
            type: "tool.result",
            payload: """
            warning: unable to access '/Users/alvaro1/.config/git/ignore': Operation not permitted
            From github.com:susom/starr-data-lake
             * branch              main       -> FETCH_HEAD
            warning: unable to access '/Users/alvaro1/.config/git/ignore': Operation not permitted
            Updating ec0d2206..d5088969
            Fast-forward
             dbt/configs/omop_atropos_phi/common | 1 +
             create mode 120000 dbt/configs/omop_atropos_phi/common
            """,
            run: run
        ))
        try context.save()

        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: context)
        try context.save()

        let summaryEvent = try #require(task.events.last { $0.type == AgentPolicyManifestService.summaryEventType })
        let object = try #require(JSONSerialization.jsonObject(with: Data(summaryEvent.payload.utf8)) as? [String: Any])
        let deniedActions = try #require(object["deniedActions"] as? [String])

        #expect(object["deniedCount"] as? Int == 0)
        #expect(deniedActions.isEmpty)
    }

    @Test("Preflight manifest replays task-scoped broker grants through the active provider adapter")
    func preflightManifestReplaysTaskScopedBrokerGrantsThroughActiveProviderAdapter() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Task Grants", primaryPath: "/tmp/task-grants-workspace")
        let task = AgentTask(title: "Task Grants", goal: "Review open PRs", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let recorded = TaskRuntimePermissionGrants.record(
            grants: [.shellCommand(executable: "gh", pattern: "search prs *")],
            providerID: .claudeCode,
            task: task,
            modelContext: context,
            source: "test"
        )
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .copilotCLI,
            model: "gpt-5",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            providerCapabilities: AgentRuntimePolicyCapabilities(
                copilotCLI: CopilotCLICapabilities(helpText: """
                --allow-tool
                --output-format
                """)
            ),
            modelContext: context
        )

        #expect(recorded == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(manifest.policyScope == .taskApproval)
        #expect(manifest.approvalGrants == [.shellCommand(executable: "gh", pattern: "search prs *")])
        #expect(manifest.providerRender.allowedTools.contains("shell(gh:search prs *)"))
        #expect(manifest.providerRender.allowedTools.contains("shell(gh:auth status *)"))
        #expect(manifest.providerRender.allowedTools.contains("shell(mkdir:-p *)"))
        #expect(!manifest.providerRender.allowedTools.contains("shell(gh:*)"))
    }

    @Test("OpenCode preflight manifest replays task-scoped broker shell grants")
    func openCodePreflightManifestReplaysTaskScopedBrokerShellGrants() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "OpenCode Grants", primaryPath: "/tmp/opencode-grants-workspace")
        let task = AgentTask(
            title: "OpenCode Grants",
            goal: "Check open PRs",
            workspace: workspace,
            model: "opencode/big-pickle"
        )
        task.runtimeID = AgentRuntimeID.openCodeCLI.rawValue
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let recorded = TaskRuntimePermissionGrants.record(
            grants: [.shellCommand(executable: "gh", pattern: "pr list *")],
            providerID: .openCodeCLI,
            task: task,
            modelContext: context,
            source: "test"
        )
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .openCodeCLI,
            model: "opencode/big-pickle",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(recorded == [.shellCommand(executable: "gh", pattern: "pr list *")])
        #expect(manifest.policyScope == .taskApproval)
        #expect(manifest.approvalGrants == [.shellCommand(executable: "gh", pattern: "pr list *")])
        #expect(manifest.providerRender.allowedTools.contains("shell(gh:pr list *)"))
        #expect(manifest.providerRender.usesBroadProviderPermissions == false)
    }

    @Test("Task-scoped grant records typed storage and legacy events remain readable")
    func taskScopedGrantRecordsTypedStorageAndReadsLegacyEvents() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Typed Grant Storage", primaryPath: "/tmp/typed-grant-workspace")
        let task = AgentTask(title: "Typed Grant Storage", goal: "Review open PRs", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let grant = PermissionGrant.shellCommand(executable: "gh", pattern: "search prs *")
        let recorded = TaskRuntimePermissionGrants.record(
            grants: [grant],
            providerID: .claudeCode,
            task: task,
            modelContext: context,
            source: "typed-test"
        )
        try context.save()

        let typedData = try #require(task.runtimePermissionGrantsJSON?.data(using: .utf8))
        let typedPayloads = try JSONDecoder().decode([TaskRuntimePermissionGrants.Payload].self, from: typedData)
        #expect(recorded == [grant])
        #expect(typedPayloads.map(\.providerID) == [.claudeCode])
        #expect(typedPayloads.flatMap(\.grants) == [grant])
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType })

        task.events.removeAll()
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .claudeCode) == [grant])
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task, runtime: .openCodeCLI).isEmpty)

        let legacyTask = AgentTask(title: "Legacy Grant Storage", goal: "Review open PRs", workspace: workspace)
        context.insert(legacyTask)
        let legacyPayload = TaskRuntimePermissionGrants.Payload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            grants: [grant],
            approvedAt: Date(),
            source: "legacy-test"
        )
        let legacyEncoded = try #require(String(data: JSONEncoder().encode(legacyPayload), encoding: .utf8))
        context.insert(TaskEvent(task: legacyTask, type: TaskRuntimePermissionGrants.eventType, payload: legacyEncoded))
        try context.save()

        #expect(TaskRuntimePermissionGrants.approvedGrants(for: legacyTask, runtime: .claudeCode) == [grant])
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: legacyTask, runtime: .openCodeCLI).isEmpty)
    }

    @Test("Task-scoped grant records reject risky shell approvals")
    func taskScopedGrantRecordsRejectRiskyShellApprovals() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Risky Grants", primaryPath: "/tmp/risky-grants-workspace")
        let task = AgentTask(title: "Risky Grants", goal: "Merge a PR", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let recorded = TaskRuntimePermissionGrants.record(
            grants: [.shellCommand(executable: "gh", pattern: "pr merge *")],
            providerID: .claudeCode,
            task: task,
            modelContext: context,
            source: "test"
        )
        try context.save()

        #expect(recorded.isEmpty)
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task).isEmpty)
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType } == false)
    }

    @Test("Task-scoped grant replay ignores stale risky shell approvals")
    func taskScopedGrantReplayIgnoresStaleRiskyShellApprovals() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Stale Risky Grants", primaryPath: "/tmp/stale-risky-grants-workspace")
        let task = AgentTask(title: "Stale Risky Grants", goal: "Merge a PR", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let payload = TaskRuntimePermissionGrants.Payload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            grants: [.shellCommand(executable: "gh", pattern: "pr merge *")],
            approvedAt: Date(),
            source: "legacy-test"
        )
        let encoded = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        context.insert(TaskEvent(task: task, type: TaskRuntimePermissionGrants.eventType, payload: encoded))
        try context.save()

        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task).isEmpty)
    }

    @Test("Preflight manifest includes active browser bridge as local tool grant")
    func preflightManifestIncludesActiveBrowserBridgeLocalToolGrant() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Browser Policy", primaryPath: "/tmp/browser-policy-workspace")
        let task = AgentTask(title: "Browser", goal: "Use the browser", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        TaskPolicyStore.recordSelection(level: .build, task: task, modelContext: context, source: "test")
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.policyLevel == .build)
        #expect(manifest.providerRender.allowedTools.contains("Bash(astra-browser *)"))
    }

    @Test("Preflight manifest uses provider launch context for scoped local tool grants")
    func preflightManifestUsesProviderLaunchContextForScopedLocalToolGrants() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let workspace = Workspace(name: "GitHub Follow-up Policy", primaryPath: "/tmp/github-followup-policy")
        workspace.enabledCapabilityIDs = [package.id]
        let skill = Skill(
            name: "GitHub Agent",
            skillDescription: "x",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "x"
        )
        skill.workspace = workspace
        let tool = LocalTool(
            name: "gh — GitHub CLI",
            toolDescription: "x",
            toolType: "cli",
            command: "gh"
        )
        tool.workspace = workspace
        let task = AgentTask(
            title: "Bake a cake",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(skill)
        context.insert(tool)
        context.insert(task)
        context.insert(run)
        TaskPolicyStore.recordSelection(level: .build, task: task, modelContext: context, source: "test")
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            contextText: "Use GitHub to list the open pull requests for this repository.",
            modelContext: context
        )

        #expect(manifest.mcpServers.contains { server in
            server.packageID == "astra-builtin"
                && server.id == HostControlPlaneMCPProjection.serverID
                && server.allowedTools == ["github"]
        })
        #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
            descriptor.name == HostControlPlaneMCPProjection.providerToolPermission(for: "github")
                && descriptor.allowedInputKeys == ["arguments", "timeout_seconds"]
        })
        #expect(!manifest.providerRender.allowedTools.contains { tool in
            let lower = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower == "bash" || lower == "shell" || lower.hasPrefix("bash(") || lower.hasPrefix("shell(")
        })
        #expect(manifest.providerRender.deniedTools.contains("Bash"))
    }

    @Test("Preflight manifest excludes pruned artifact task capabilities")
    func preflightManifestExcludesPrunedArtifactTaskCapabilities() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Artifact Policy", primaryPath: "/tmp/artifact-policy-workspace")
        let skill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Read Stanford email through Microsoft Graph",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: "Do NOT use Write or Edit.",
            environmentVariables: ["MAIL_PROFILE": "stanford"]
        )
        skill.workspace = workspace
        let tool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read Stanford mail",
            command: "stanford-graph-mail"
        )
        tool.skill = skill
        let task = AgentTask(
            title: "Create Masterball puzzle solver webpage",
            goal: "create a web page with a masterball solver in javascript",
            workspace: workspace
        )
        task.skills = [skill]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(skill)
        context.insert(tool)
        context.insert(task)
        context.insert(run)
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: AgentRuntimeExecutionPolicy(
                permissionPolicyOverride: nil,
                allowedToolsOverride: ["Bash"],
                permissionGrantsOverride: nil
            ),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.environmentKeyNames.isEmpty)
        #expect(!manifest.providerRender.allowedTools.contains("Bash(stanford-graph-mail *)"))
        #expect(!manifest.providerRender.generatedConfigPreview.contains("stanford-graph-mail"))
    }

    @Test("Preflight manifest includes catalog-approved MCP servers")
    func preflightManifestIncludesCatalogApprovedMCPServers() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "MCP Policy", primaryPath: "/tmp/mcp-policy-workspace")
        let package = PluginPackage(
            id: "mcp-policy-package",
            name: "MCP Policy Package",
            icon: "server.rack",
            description: "MCP manifest package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "github",
                    displayName: "GitHub MCP",
                    transport: .stdio,
                    command: "github-mcp-server",
                    arguments: ["stdio"],
                    allowedTools: ["issues.list"],
                    excludedTools: ["repo.delete"],
                    resourcesEnabled: true,
                    promptsEnabled: true,
                    trustLevel: .high
                )
            ],
            templates: [],
            governance: .builtInApproved(riskLevel: .high)
        )
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(title: "MCP", goal: "Use MCP", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            modelContext: context
        )

        #expect(manifest.mcpServers.count == 1)
        #expect(manifest.mcpServers.first?.packageID == package.id)
        #expect(manifest.mcpServers.first?.id == "github")
        #expect(manifest.mcpServers.first?.allowedTools == ["issues.list"])
        #expect(manifest.mcpServers.first?.excludedTools == ["repo.delete"])
        #expect(manifest.mcpServers.first?.resourcesEnabled == true)
        #expect(manifest.mcpServers.first?.promptsEnabled == true)
        #expect(manifest.mcpServers.first?.trustLevel == "high")
    }
}
