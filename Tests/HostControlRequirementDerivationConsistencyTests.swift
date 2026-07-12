import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels

/// Regression coverage for the 9FA6AF3D incident (2026-07-10): a resumed,
/// multi-turn, autonomous-policy task using the github-workflow capability
/// reached `runtime.command_planned` / `policy_blocked` on Cursor CLI with
/// *no* prior reroute and *no* pre-launch compatibility block — even though
/// Cursor cannot deliver the host-control MCP route for GitHub. That can only
/// happen if `AgentRuntimeLaunchRuntimeResolver` (which decides whether to
/// reroute or block *before* launch) and the policy render / preflight
/// manifest (which raises the `cursor_cli.host-control-plane-unsupported`
/// `.blocked` diagnostic) disagree about whether the task needs host-control
/// MCP at all — despite both being derived, via
/// `HostControlPlaneMCPProjection.requiredToolNames(capabilityScope:)`, from
/// what should be equivalent `TaskCapabilityResolutionSnapshot` captures.
@Suite("Host-control requirement derivation consistency")
struct HostControlRequirementDerivationConsistencyTests {

    /// Proves the Phase 1 fix's plumbing is real: when
    /// `recordPreflightManifest` is handed a precomputed
    /// `TaskRuntimeRequirementSet` (as the production launch path now always
    /// does via `AgentRuntimeLaunchRuntimeResolver`), that value must be
    /// authoritative — the policy render must not silently re-derive its own
    /// answer from a second capability-scope capture and disagree with it.
    /// Without the Phase 1 wiring (i.e. if `precomputedRuntimeRequirements`
    /// were ignored), both calls below would produce the same `.blocked`
    /// diagnostic and this test would fail.
    @Test("a precomputed requirement set overrides independent re-derivation in the policy render")
    @MainActor
    func precomputedRequirementsAreAuthoritativeInPolicyRender() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "Cursor GitHub Metadata", primaryPath: "/tmp/astra-cursor-github-metadata-2")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "Precomputed requirements authority check",
            goal: "Use GitHub to find the pull request and issue metadata for this task",
            workspace: workspace,
            runtime: .cursorCLI
        )
        context.insert(workspace)
        context.insert(task)

        func blockedHostControlDiagnostic(precomputed: TaskRuntimeRequirementSet?) throws -> PolicyDiagnostic? {
            let run = TaskRun(task: task)
            context.insert(run)
            let manifest = AgentPolicyManifestService.recordPreflightManifest(
                task: task,
                run: run,
                runtime: .cursorCLI,
                model: "composer-2.5-fast",
                workspacePath: workspace.primaryPath,
                phase: "resume",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                capabilityPackages: [package],
                contextText: "Use GitHub to inspect PR metadata, issue links, and checks for this task.",
                precomputedRuntimeRequirements: precomputed,
                modelContext: context
            )
            return manifest.providerRender.diagnostics.first { $0.id == "cursor_cli.host-control-plane-unsupported" }
        }

        // Baseline: without an override, the render independently derives the
        // requirement from the task's own capability scope and blocks — same
        // as the always-live cursorPreflightNamesHostControlIncompatibilityForGitHubMetadata.
        let baseline = try blockedHostControlDiagnostic(precomputed: nil)
        #expect(baseline != nil)

        // With an explicit (deliberately empty) precomputed requirement set —
        // as if the launch resolver had already determined no host-control
        // MCP is needed — the render must defer to it instead of re-deriving
        // its own, contradicting answer.
        let overridden = try blockedHostControlDiagnostic(precomputed: TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        ))
        #expect(overridden == nil)
    }

    /// Directly compares the two independently-captured snapshots used by
    /// (1) the compatibility resolver and (2) the policy render, for a task
    /// shaped like 9FA6AF3D: multiple prior turns/runtime switches already in
    /// history, a persisted skill snapshot from an earlier run, autonomous
    /// policy, and a short generic follow-up message that does not itself
    /// repeat GitHub keywords (mirroring the 43-character resume message from
    /// the incident trace). If these two derivations can disagree, a task can
    /// sail past the resolver (no reroute, no early block) and only fail much
    /// later as an opaque `policy_blocked` run with no actionable remediation
    /// surfaced up front.
    @Test("resolver-time and render-time host-control requirement derivation agree")
    @MainActor
    func resolverAndRenderAgreeOnHostControlRequirement() throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "List my open PRs in the astra repo and summarize CI status",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: """
            Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub \
            operations. Always use ASTRA MCP tools for GitHub; do not use bash gh or git \
            push directly for GitHub API work.
            """
        )
        githubSkill.skillDescription = "Inspect issues, PRs, and CI via ASTRA host-control GitHub"
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        // Build up multi-turn history (history_run_count=6 in the incident)
        // and a persisted skill snapshot from an earlier run, matching
        // task_skill_snapshot_count=1 in the trace.
        for index in 0..<5 {
            let priorRun = TaskRun(task: task)
            priorRun.runtimeID = index.isMultiple(of: 2)
                ? AgentRuntimeID.codexCLI.rawValue
                : AgentRuntimeID.cursorCLI.rawValue
            priorRun.status = .completed
            priorRun.output = "Prior turn \(index) output"
            harness.context.insert(priorRun)
        }
        task.skillSnapshots = [SkillSnapshotConfig(skill: githubSkill)]
        task.status = .completed
        task.runtimeID = AgentRuntimeID.cursorCLI.rawValue

        let executionPolicy = AgentRuntimeExecutionPolicy.default
        let followUpMessage = "please go ahead and merge it"

        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
        let promptOverride = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: followUpMessage,
            task: task,
            executionPolicy: executionPolicy
        )
        let startPayload = adapter.defaultStartEventPayload(task: task)
        let contextText = adapter.connectorPreflightContextText(
            task: task,
            promptOverride: promptOverride,
            startPayload: startPayload,
            sessionMessage: followUpMessage,
            phase: .resume
        )
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)

        // Mirrors AgentRuntimeLaunchRuntimeResolver.resolve's internal capture
        // (Astra/Services/Runtime/AgentRuntimeLaunchRuntimeResolver.swift).
        let resolverSnapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? []
        )
        let resolverRequirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: resolverSnapshot,
            executionEnvironment: executionEnvironment,
            browserBridgeAttached: false
        )

        // Mirrors AgentRuntimeWorker.executeRuntimeSession's
        // capabilityResolutionSnapshot, which flows into the policy render /
        // recordPreflightManifest (Astra/Services/Runtime/AgentRuntimeWorker.swift).
        let renderSnapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? [],
            exposeAllConnectorCredentials: true
        )
        let renderHostControlTools = HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: executionEnvironment,
            contextText: contextText,
            capabilityScope: renderSnapshot.providerLaunch
        )

        #expect(
            resolverRequirements.hostControlTools == renderHostControlTools,
            """
            resolver derived hostControlTools=\(resolverRequirements.hostControlTools) but \
            policy render derived hostControlTools=\(renderHostControlTools) for the identical \
            task/turn. The compatibility resolver (which decides reroute-vs-block before launch) \
            and the policy-render gate (which raises cursor_cli.host-control-plane-unsupported as \
            a hard block) must agree, or a task can pass the resolver silently and only fail much \
            later as an unexplained policy_blocked run.
            """
        )
    }

    /// Extends the resolver-vs-render parity check above one layer deeper: the
    /// actual RUNTIME LAUNCH PROJECTION that builds the real MCP-server-
    /// attachment config passed to the provider process. A Codex-review
    /// follow-up on this PR found that `recordPreflightManifest`'s
    /// `precomputedRuntimeRequirements` plumbing only reached the *manifest*
    /// (which decides whether to raise a `.blocked` diagnostic) — the actual
    /// Copilot launch path (`CopilotMCPLaunchProjection.resolve` /
    /// `CopilotRuntimeLaunchSupport.HostControlPlaneRuntimeLaunchGuard`) still
    /// independently re-derived its own host-control tool list from a second
    /// capability-scope capture. That reintroduces the exact "two independent
    /// captures can disagree" risk one layer deeper: the manifest could
    /// conclude "compatible, no block" while the actual launch attaches a
    /// different tool set — or hard-blocks with
    /// `host_control_plane_unsupported_runtime` anyway — losing the structured
    /// `runtime.launch_blocked` remediation the manifest path already computed.
    @Test("resolver's TaskRuntimeRequirementSet and Copilot's actual launch projection agree on host-control tool attachment")
    @MainActor
    func resolverAndCopilotLaunchProjectionAgreeOnHostControlRequirement() throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "List my open PRs in the astra repo and summarize CI status",
            model: "gpt-5"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: """
            Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub \
            operations. Always use ASTRA MCP tools for GitHub; do not use bash gh or git \
            push directly for GitHub API work.
            """
        )
        githubSkill.skillDescription = "Inspect issues, PRs, and CI via ASTRA host-control GitHub"
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        // Multi-turn resumed-task shape, mirroring
        // resolverAndRenderAgreeOnHostControlRequirement above.
        for index in 0..<5 {
            let priorRun = TaskRun(task: task)
            priorRun.runtimeID = index.isMultiple(of: 2)
                ? AgentRuntimeID.codexCLI.rawValue
                : AgentRuntimeID.copilotCLI.rawValue
            priorRun.status = .completed
            priorRun.output = "Prior turn \(index) output"
            harness.context.insert(priorRun)
        }
        task.skillSnapshots = [SkillSnapshotConfig(skill: githubSkill)]
        task.status = .completed
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue

        let executionPolicy = AgentRuntimeExecutionPolicy.default
        let followUpMessage = "please go ahead and merge it"

        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let promptOverride = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: followUpMessage,
            task: task,
            executionPolicy: executionPolicy
        )
        let startPayload = adapter.defaultStartEventPayload(task: task)
        let contextText = adapter.connectorPreflightContextText(
            task: task,
            promptOverride: promptOverride,
            startPayload: startPayload,
            sessionMessage: followUpMessage,
            phase: .resume
        )
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)

        // Mirrors AgentRuntimeLaunchRuntimeResolver.resolve's internal capture
        // and derivation exactly
        // (Astra/Services/Runtime/AgentRuntimeLaunchRuntimeResolver.swift).
        let resolverSnapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionPolicy.permissionGrantsOverride ?? []
        )
        let resolverRequirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: resolverSnapshot,
            executionEnvironment: executionEnvironment,
            browserBridgeAttached: false
        )
        #expect(resolverRequirements.hostControlTools == ["github"])

        // Feed the resolver's own answer into the ACTUAL Copilot launch
        // projection, exactly as production code
        // (CopilotCLIRuntimeAdapter.makeProcessLaunchPlan, via
        // AgentRuntimeProcessLaunchContext.runtimeRequirements) now does. Use
        // .conservative capabilities (no --additional-mcp-config support) to
        // reproduce the reviewer-cited failure mode: a Copilot CLI build that
        // cannot attach ASTRA's host-control MCP server at all.
        let mcpProjection = CopilotMCPLaunchProjection.resolve(
            task: task,
            workspacePath: task.workspace?.primaryPath ?? "",
            runID: nil,
            executionEnvironment: executionEnvironment,
            contextText: contextText,
            capabilities: .conservative,
            runtimeRequirements: resolverRequirements
        )
        let launchAttachedTools = HostControlPlaneRuntimeLaunchGuard.requiredTools(
            from: mcpProjection.hostControlEnvironment
        )

        #expect(
            launchAttachedTools == resolverRequirements.hostControlTools,
            """
            resolver derived hostControlTools=\(resolverRequirements.hostControlTools) but Copilot's \
            actual launch projection attached hostControlEnvironment tools=\(launchAttachedTools) for \
            the identical task/turn. AgentRuntimeLaunchRuntimeResolver (which decides reroute-vs-block \
            before launch) and CopilotMCPLaunchProjection (which builds the real MCP-server-attachment \
            config passed to the Copilot CLI process) must agree, or the manifest can suppress its \
            blocked diagnostic while the actual launch's HostControlPlaneRuntimeLaunchGuard still stops \
            the run with host_control_plane_unsupported_runtime, losing the structured \
            runtime.launch_blocked remediation.
            """
        )
        // With .conservative (no --additional-mcp-config) capabilities and a
        // non-empty required-tool list, the actual launch must report the
        // exact block reason the reviewer's incident lost.
        #expect(mcpProjection.hostControlPlaneSupported == false)
        #expect(mcpProjection.hostControlPlaneLaunchBlockReason == HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)
    }

    /// Proves the launch-projection plumbing above is real wiring, not
    /// coincidental agreement: a deliberately different precomputed
    /// `TaskRuntimeRequirementSet` must be authoritative over independent
    /// re-derivation, exactly mirroring
    /// `precomputedRequirementsAreAuthoritativeInPolicyRender` above but one
    /// layer deeper — at the actual MCP-server-attachment call site instead of
    /// the manifest. Without the fix (`CopilotMCPLaunchProjection.resolve`
    /// accepting and honoring `runtimeRequirements`), this test does not even
    /// compile.
    @Test("a precomputed requirement set overrides independent re-derivation in Copilot's actual launch projection")
    @MainActor
    func precomputedRequirementsAreAuthoritativeInCopilotLaunchProjection() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "Copilot GitHub Metadata", primaryPath: "/tmp/astra-copilot-github-metadata")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "Copilot launch-projection authority check",
            goal: "Use GitHub to find the pull request and issue metadata for this task",
            workspace: workspace,
            runtime: .copilotCLI
        )
        context.insert(workspace)
        context.insert(task)

        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let contextText = "Use GitHub to inspect PR metadata, issue links, and checks for this task."

        func launchBlockReason(precomputed: TaskRuntimeRequirementSet?) -> String {
            let mcpProjection = CopilotMCPLaunchProjection.resolve(
                task: task,
                workspacePath: workspace.primaryPath,
                runID: nil,
                executionEnvironment: executionEnvironment,
                contextText: contextText,
                capabilities: .conservative,
                runtimeRequirements: precomputed
            )
            return mcpProjection.hostControlPlaneLaunchBlockReason
        }

        // Baseline: without an override, the launch projection independently
        // derives the requirement from the task's own capability scope and
        // blocks — same as the always-live capability-scope-driven behavior.
        #expect(launchBlockReason(precomputed: nil) == HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)

        // With an explicit (deliberately empty) precomputed requirement set —
        // as if the launch resolver had already determined no host-control
        // MCP is needed — the actual launch projection must defer to it
        // instead of re-deriving its own, contradicting answer.
        #expect(launchBlockReason(precomputed: TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )) == "none")
    }

    /// Extends the resolver-vs-render parity guarantee one layer deeper
    /// still: `TaskLaunchResourceResolver`, which independently decides —
    /// via its private `routesGitHubMetadataThroughHostControl` — whether
    /// GitHub work should route through ASTRA's host-control MCP
    /// (suppressing native git/gh credential projection) or fall back to
    /// native git/gh credentials instead. A Codex-review follow-up on this
    /// PR found this was the one remaining consumer `AgentRuntimeWorker`
    /// never threaded `appliedRuntime.requirements` into:
    /// `TaskLaunchResourceResolver.resolve` built `launchResourcePlan` using
    /// its own second, independently-captured capability-scope derivation of
    /// GitHub host-control availability
    /// (`Astra/Services/Runtime/TaskLaunchResourceResolver.swift`). If that
    /// independent derivation disagrees with the actual
    /// `TaskRuntimeRequirementSet` (e.g. the real resolved requirements omit
    /// "github" from `hostControlTools` while the resource resolver's own
    /// capability-scope-based check says GitHub host-control is available),
    /// the resource resolver suppresses native git/gh credential projection
    /// assuming host control will cover it — while nothing downstream
    /// actually attaches that host-control route, since the rest of the
    /// launch pipeline follows the real (disagreeing) requirement set. Net
    /// effect: neither credential path is active for that run.
    @Test("a precomputed requirement set overrides independent re-derivation in TaskLaunchResourceResolver's GitHub routing")
    @MainActor
    func precomputedRequirementsAreAuthoritativeInResourceResolver() throws {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-resolver-precomputed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let gitCredentialPath = workspaceRoot.appendingPathComponent("host-gitconfig")
        try "[credential]\nhelper = osxkeychain\n".write(to: gitCredentialPath, atomically: true, encoding: .utf8)

        // Mirrors githubMetadataRoutesThroughHostControlWithoutGitCredentialProjection
        // in Tests/TaskLaunchResourcePlanTests.swift: a task whose own
        // capability scope (enabledCapabilityIDs includes the GitHub
        // package) makes the resolver's independent derivation say "route
        // through host control" for this prompt/context.
        let workspace = Workspace(name: "GitHub Metadata Precomputed", primaryPath: workspaceRoot.path)
        workspace.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let task = AgentTask(
            title: "Review PR metadata",
            goal: "Use GitHub to inspect pull request metadata and checks",
            workspace: workspace
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: "Use GitHub to list open pull requests and check statuses."
        )

        func resolve(
            precomputed: TaskRuntimeRequirementSet?
        ) -> (plan: TaskLaunchResourcePlan, gitCredentialProviderWasCalled: Bool) {
            var gitCredentialProviderWasCalled = false
            let plan = TaskLaunchResourceResolver.resolve(
                task: task,
                runID: UUID(),
                runtime: .claudeCode,
                phase: "resume",
                prompt: "Review PR metadata",
                contextText: "Use GitHub to list open pull requests and check statuses.",
                workspacePath: workspaceRoot.path,
                capabilityResolutionSnapshot: snapshot,
                gitCredentialContextProvider: { _, _, _, _ in
                    gitCredentialProviderWasCalled = true
                    return GitCredentialSandboxContext(
                        readablePaths: [gitCredentialPath.path],
                        writablePaths: [],
                        transports: [.https],
                        diagnostics: []
                    )
                },
                precomputedRuntimeRequirements: precomputed
            )
            return (plan, gitCredentialProviderWasCalled)
        }

        // Baseline: without an override, the resolver independently derives
        // "github routes through host control" from the task's own
        // capability scope and suppresses native git credential projection —
        // same as the always-live
        // githubMetadataRoutesThroughHostControlWithoutGitCredentialProjection.
        let baseline = resolve(precomputed: nil)
        #expect(!baseline.gitCredentialProviderWasCalled)
        #expect(baseline.plan.gitCredential == nil)

        // With an explicit precomputed requirement set whose hostControlTools
        // omits "github" — as if AgentRuntimeLaunchRuntimeResolver had
        // already determined the actual launch will NOT attach a GitHub
        // host-control route — the resource resolver must defer to it
        // instead of re-deriving its own, contradicting answer that would
        // otherwise leave neither credential path active for the run.
        let overridden = resolve(precomputed: TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        ))
        #expect(overridden.gitCredentialProviderWasCalled)
        #expect(overridden.plan.gitCredential != nil)
        #expect(overridden.plan.credentialGrants.contains { $0.source == .gitCredential })
    }

    /// Phase 2 (D1): when the user explicitly pinned Cursor for this task
    /// (`runtimeExplicitlySelected`), an incompatible requirement must not be
    /// silently overridden by rerouting to Codex — it must block up front
    /// with the real remediation, before any provider process launches. This
    /// is the explicit-pick counterpart to
    /// `githubHostControlRetryReroutesFromCursorToConfiguredCompatibleRuntime`
    /// in HeadlessChatContinuationScenarioTests.swift, which covers the
    /// default (non-explicit) case and must keep silently rerouting.
    @Test("explicitly-selected incompatible runtime blocks before launch instead of rerouting")
    @MainActor
    func explicitlySelectedIncompatibleRuntimeBlocksBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 1
            """
        )
        let codexPath = try harness.writeExecutable(
            named: "codex",
            script: """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-github-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex GitHub answer"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "List my open PRs in the astra repo",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: "Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub operations."
        )
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        // The critical setup difference from the default-reroute test: the
        // user explicitly picked Cursor via the composer's runtime switcher.
        task.runtimeExplicitlySelected = true

        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .codexCLI
        worker.setExecutablePath(codexPath, for: .codexCLI)
        worker.setHomeDirectory(
            harness.rootURL.appendingPathComponent("codex-home", isDirectory: true).path,
            for: .codexCLI
        )

        _ = await harness.continueTask(
            task: task,
            message: "retry listing my open PRs in the astra repo",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        // Must stay on Cursor (not silently rerouted to Codex) and must not
        // have launched the Cursor process at all (block happens pre-launch).
        #expect(task.runtimeID == AgentRuntimeID.cursorCLI.rawValue)
        #expect(run.runtimeID == AgentRuntimeID.cursorCLI.rawValue)
        #expect(!task.events.contains { $0.payload.contains("Runtime changed from Cursor CLI") })
        #expect(run.typedStopReason == .runtimeCapabilityIncompatible)
        // A compatible fallback (Codex) exists in this harness, so the block
        // names it specifically instead of the generic multi-option text —
        // both in the human-readable audit event and the structured sibling
        // event the decision dock actually reads.
        #expect(task.events.contains { $0.payload.contains("Switch to Codex CLI.") })
        #expect(task.events.contains { $0.payload.contains("Suggested runtime: codex_cli") })
        let structuredBlock = try #require(
            task.events
                .first { $0.type == TaskEventTypes.System.runtimeLaunchBlocked.rawValue }
                .flatMap { TaskRunLaunchBlockPayload.decode(from: $0.payload) }
        )
        #expect(structuredBlock.kind == .runtimeIncompatible)
        #expect(structuredBlock.suggestedRuntimeID == "codex_cli")
        #expect(structuredBlock.remediation == "Switch to Codex CLI.")

        // The actual reachability bug this scenario guards against: before
        // the typed isPolicyBlocked fix, runtime_capability_incompatible
        // never satisfied the substring heuristic, so this dismissal reason
        // was always nil and the whole truthful-UI + switch-runtime dock
        // feature was unreachable for the exact case it was built for.
        #expect(PendingTaskReviewPolicy.dismissalReason(for: task, latestRun: run) == .policyBlocked)
    }

    /// End-to-end companion: drives the same scenario through the real
    /// worker resume path (continueSession) and asserts the task never ends
    /// up `pending_user`/`policy_blocked` on Cursor without either a visible
    /// reroute event or a pre-launch compatibility block event — i.e. it
    /// must not go silent. This is the outward-observable shape of the
    /// 9FA6AF3D incident.
    @Test("resumed autonomous GitHub task never reaches a silent policy_blocked failure on an incompatible runtime")
    @MainActor
    func resumedTaskDoesNotReachSilentPolicyBlock() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let cursorPath = try harness.writeExecutable(
            named: "cursor-agent",
            script: """
            printf '%s\\n' 'Cursor provider should not launch for GitHub host-control work'
            exit 1
            """
        )
        let codexPath = try harness.writeExecutable(
            named: "codex",
            script: """
            #!/bin/sh
            printf '%s\\n' '{"type":"thread.started","thread_id":"codex-github-thread"}'
            printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex GitHub answer"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .cursorCLI,
            goal: "List my open PRs in the astra repo and summarize CI status",
            model: "composer-2.5-fast"
        )
        task.workspace?.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: """
            Use ASTRA's host-control GitHub MCP tool mcp__astra_host__github for GitHub \
            operations. Always use ASTRA MCP tools for GitHub; do not use bash gh or git \
            push directly for GitHub API work.
            """
        )
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = task.workspace
        task.skills = [githubSkill]
        harness.context.insert(githubSkill)

        for index in 0..<5 {
            let priorRun = TaskRun(task: task)
            priorRun.runtimeID = index.isMultiple(of: 2)
                ? AgentRuntimeID.codexCLI.rawValue
                : AgentRuntimeID.cursorCLI.rawValue
            priorRun.status = .completed
            priorRun.output = "Prior turn \(index) output"
            harness.context.insert(priorRun)
        }
        task.skillSnapshots = [SkillSnapshotConfig(skill: githubSkill)]
        task.status = .completed

        // Explicit user runtime pick, same as task_runtime_changed -> cursor_cli
        // at 22:46:15 in the incident.
        let worker = harness.makeWorker(
            runtime: .cursorCLI,
            executablePath: cursorPath,
            permissionPolicy: .autonomous
        )
        worker.defaultRuntimeID = .codexCLI
        worker.setExecutablePath(codexPath, for: .codexCLI)
        worker.setHomeDirectory(
            harness.rootURL.appendingPathComponent("codex-home", isDirectory: true).path,
            for: .codexCLI
        )
        task.runtimeID = AgentRuntimeID.cursorCLI.rawValue
        task.runtimeExplicitlySelected = true

        _ = await harness.continueTask(
            task: task,
            message: "please go ahead and merge it",
            worker: worker
        )

        let run = try #require(task.runs.sorted { $0.startedAt < $1.startedAt }.last)
        let rerouted = task.events.contains { event in
            event.type == TaskEventTypes.System.info.rawValue
                && event.payload.contains("Runtime changed from Cursor CLI")
        }
        let blockedUpFront = run.status == .failed
            && (run.typedStopReason?.rawValue == "runtime_capability_incompatible"
                || run.typedStopReason?.rawValue == HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)

        #expect(
            rerouted || blockedUpFront || run.runtimeID != AgentRuntimeID.cursorCLI.rawValue,
            """
            Task resumed on an explicitly-pinned but host-control-incompatible runtime \
            (Cursor CLI) with neither a visible reroute nor a pre-launch compatibility block \
            (run.status=\(run.status), run.runtimeID=\(run.runtimeID ?? "nil"), \
            stopReason=\(run.typedStopReason?.rawValue ?? "nil")). This reproduces the \
            9FA6AF3D shape: the run silently proceeded past the compatibility resolver and \
            only failed later as an opaque policy_blocked run.
            """
        )
    }
}
