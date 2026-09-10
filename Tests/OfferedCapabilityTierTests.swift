import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Offered is permissive, never obligatory. Widening what a run *may* reach
/// must not widen what it *requires*, because the required tier is the only one
/// with teeth: it reroutes runs, aborts launches, and withdraws native shell.
/// Every surface in here once derived "required" from the offered set, which
/// turned one enabled connector into a workspace-wide launch failure.
@Suite("Offered capability tier")
@MainActor
struct OfferedCapabilityTierTests {
    @Test("An offered-only host tool never blocks a Copilot launch")
    func offeredOnlyHostToolNeverBlocksCopilotLaunch() throws {
        let fixture = try Fixture()
        // Copilot without --additional-mcp-config: this build cannot carry the
        // host-control MCP server at all.
        let capabilities = CopilotCLICapabilities(helpText: "--output-format=FORMAT --no-ask-user")

        func projection(contextText: String) -> CopilotMCPLaunchProjection {
            CopilotMCPLaunchProjection.resolve(
                task: fixture.task,
                workspacePath: fixture.workspace.primaryPath,
                runID: UUID(),
                executionEnvironment: .host,
                contextText: contextText,
                capabilities: capabilities
            )
        }

        // The turn never mentions Jira. The connector is enabled, so it is
        // offered - and an offered route this build cannot carry is dropped,
        // not turned into a launch block.
        let offeredOnly = projection(contextText: fixture.unrelatedTurn)
        #expect(offeredOnly.hostControlPlaneSupported)
        #expect(offeredOnly.hostControlPlaneLaunchBlockReason == "none")
        #expect(offeredOnly.hostControlPlaneUnsupportedDetail.isEmpty)
        // The env named a broker socket no MCP server was written for; leaving
        // it in place tells the policy manifest a dead route is live.
        #expect(offeredOnly.hostControlEnvironment.isEmpty)

        // The turn that actually asks for Jira still blocks, because now the
        // run cannot deliver what it was asked to do.
        let required = projection(contextText: fixture.jiraTurn)
        #expect(!required.hostControlPlaneSupported)
        #expect(required.hostControlPlaneLaunchBlockReason
            == HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)
        #expect(required.hostControlPlaneUnsupportedDetail.contains("jira"))
    }

    @Test("An offered-only connector is not a required provider requirement")
    func offeredOnlyConnectorIsNotARequiredProviderRequirement() throws {
        let fixture = try Fixture()

        func connectorRequirement(contextText: String) throws -> RuntimeProviderRequirement {
            let plan = TaskLaunchResourceResolver.resolve(
                task: fixture.task,
                runID: UUID(),
                runtime: .claudeCode,
                phase: .run,
                prompt: contextText,
                contextText: contextText,
                workspacePath: fixture.workspace.primaryPath,
                executionEnvironment: .host,
                connectorSecretStore: fixture.store
            )
            return try #require(plan.providerRequirements.first { $0.capability == "connector:jira" })
        }

        // Wired either way - reachability is what makes the route usable at
        // all - but only the turn that names it may be a hard requirement.
        #expect(try connectorRequirement(contextText: fixture.jiraTurn).required)
        #expect(try !connectorRequirement(contextText: fixture.unrelatedTurn).required)
    }

    @Test("An offered-only browser bridge does not require browser control")
    func offeredOnlyBrowserBridgeDoesNotRequireBrowserControl() throws {
        let fixture = try Fixture()
        let browserTool = LocalTool(
            name: "ASTRA Browser",
            toolDescription: "Drive a browser session",
            command: "astra-browser"
        )
        browserTool.workspace = fixture.workspace
        fixture.context.insert(browserTool)
        try fixture.context.save()

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: fixture.unrelatedTurn,
            secretStore: fixture.store
        )
        let scope = snapshot.providerLaunch
        // Enabled, so the transport is attached where it can be.
        #expect(scope.exposesBrowserBridge)
        // But this turn is about a cake. Requiring browser control here would
        // reroute every turn in the workspace onto a browser-capable runtime.
        #expect(!scope.requiresBrowserBridge)
        #expect(!TaskRuntimeRequirementSet.derive(
            task: fixture.task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeRequired: scope.requiresBrowserBridge
        ).requiresBrowserControl)
    }

    @Test("An offered brokered connector stays in the manifest without its secret")
    func offeredBrokeredConnectorStaysInTheManifestWithoutItsSecret() throws {
        let fixture = try Fixture(includingREDCap: true)
        let redcap = try #require(fixture.redcapConnector)
        let scope = fixture.scope(for: fixture.jiraTurn)
        // The turn names Jira and nothing else, so REDCap is reachable-only.
        #expect(scope.connectors.contains { $0.id == fixture.jiraConnector.id })
        #expect(!scope.connectors.contains { $0.id == redcap.id })
        #expect(scope.reachableConnectors.contains { $0.id == redcap.id })

        let environment = HostControlBrokerSessionRegistry.brokeredConnectorEnvironment(
            task: fixture.task,
            runtime: .claudeCode,
            capabilityScope: scope,
            requiredTools: ["jira", "redcap"],
            secretStore: fixture.store
        )
        let manifest = try #require(environment["ASTRA_CONNECTORS"]).lowercased()
        // Both routes are advertised. Projecting the two tiers separately and
        // merging the results drops one connector from the manifest, and the
        // broker then answers "not projected into ASTRA_CONNECTORS" for a route
        // the prompt just told the agent to use.
        #expect(manifest.contains(fixture.jiraConnector.id.uuidString.lowercased()))
        #expect(manifest.contains(redcap.id.uuidString.lowercased()))
        // The tier survives as a credential policy, not as a missing manifest
        // entry: only the narrated connector's secret is unsealed.
        #expect(environment.values.contains(Fixture.jiraSecret))
        #expect(!environment.values.contains(Fixture.redcapSecret))
    }

    @Test("Brokered credential labels report only what the broker will unseal")
    func brokeredCredentialLabelsReportOnlyWhatTheBrokerWillUnseal() throws {
        let fixture = try Fixture(includingREDCap: true)
        let redcap = try #require(fixture.redcapConnector)
        let scope = fixture.scope(for: fixture.jiraTurn)
        let jiraLabel = ConnectorRuntimeProjection.credentialLabel(
            for: fixture.jiraConnector,
            key: "JIRA_API_TOKEN"
        )
        let redcapLabel = ConnectorRuntimeProjection.credentialLabel(for: redcap, key: "REDCAP_API_TOKEN")

        // The strip stays reachability-wide - the agent must not hold either
        // token - but the *report* says what is usable, and an unapproved
        // reachable connector is not.
        #expect(BrokeredConnectorEnvironment.brokeredConnectors(in: scope).contains { $0.id == redcap.id })
        let reported = BrokeredConnectorEnvironment.credentialLabels(
            in: scope,
            task: fixture.task,
            runtime: .claudeCode
        )
        #expect(reported.contains(jiraLabel))
        #expect(!reported.contains(redcapLabel))

        // A durable grant is what makes it usable, so now it is reported.
        _ = TaskRuntimePermissionGrants.record(
            grants: [.credential(label: redcapLabel)],
            providerID: .claudeCode,
            task: fixture.task,
            modelContext: fixture.context,
            source: "test"
        )
        #expect(BrokeredConnectorEnvironment.credentialLabels(
            in: scope,
            task: fixture.task,
            runtime: .claudeCode
        ).contains(redcapLabel))
    }

    @Test("A Copilot build that can carry the broker is not told the route is unavailable")
    func copilotThatCanCarryTheBrokerIsNotToldTheRouteIsUnavailable() throws {
        let fixture = try Fixture()
        let scope = fixture.scope(for: fixture.jiraTurn)

        func connectorSectionText(supportsAdditionalMCPConfig: Bool) throws -> String {
            try #require(AgentPromptConnectorContextBuilder.section(
                from: scope,
                task: fixture.task,
                runtime: .copilotCLI,
                runtimeCapabilityProfile: .copilotProfile(
                    supportsAdditionalMCPConfig: supportsAdditionalMCPConfig
                )
            )).text
        }

        // The static table says Copilot cannot carry the host control plane. A
        // build with --additional-mcp-config can, and the launch attaches the
        // route - printing "Route UNAVAILABLE" over it makes the agent report a
        // working connector as broken.
        #expect(!(try connectorSectionText(supportsAdditionalMCPConfig: true)).contains("Route UNAVAILABLE"))
        #expect((try connectorSectionText(supportsAdditionalMCPConfig: false)).contains("Route UNAVAILABLE"))
    }

    @Test("The launch plan records a broker route only when the runtime can carry it")
    func launchPlanRecordsBrokerRouteOnlyWhenTheRuntimeCanCarryIt() throws {
        let fixture = try Fixture()

        func recordsJiraConnectorRoute(supportsAdditionalMCPConfig: Bool) -> Bool {
            TaskLaunchResourceResolver.resolve(
                task: fixture.task,
                runID: UUID(),
                runtime: .copilotCLI,
                phase: .run,
                prompt: fixture.jiraTurn,
                contextText: fixture.jiraTurn,
                workspacePath: fixture.workspace.primaryPath,
                executionEnvironment: .host,
                connectorSecretStore: fixture.store,
                runtimeCapabilityProfile: .copilotProfile(
                    supportsAdditionalMCPConfig: supportsAdditionalMCPConfig
                )
            )
            .controlPlaneResources
            .contains { $0.capability == "jira" && $0.source == .connector }
        }

        // Offered says what the run *may* attach, not that this runtime can
        // carry any of it. A control-plane resource on a runtime with no
        // transport writes a route into the persisted plan that nothing serves,
        // and the plan is what Run Activity reads back.
        #expect(recordsJiraConnectorRoute(supportsAdditionalMCPConfig: true))
        #expect(!recordsJiraConnectorRoute(supportsAdditionalMCPConfig: false))
    }

    @Test("A host tool declared by an unnarrated skill is offered, never required")
    func hostToolDeclaredByUnnarratedSkillIsOfferedNeverRequired() throws {
        let snapshot = HostControlPlaneMCPProjection.CapabilitySnapshot(
            enabledPackageIDs: [],
            behaviorSkillOriginPackageIDs: [],
            // This turn's wording dropped the skill that declares the route...
            effectiveBehaviorInstructions: [],
            // ...but the workspace still enables it.
            reachableBehaviorInstructions: [
                "Always use the host-control mcp__astra_host__bq tool for warehouse queries."
            ]
        )
        #expect(HostControlPlaneMCPProjection.offeredToolNames(capabilitySnapshot: snapshot).contains("bq"))
        #expect(!HostControlPlaneMCPProjection.requiredToolNames(capabilitySnapshot: snapshot).contains("bq"))

        // And the scope really does carry behavior text past the turn filter,
        // which is what makes the offered read above reach anything at all.
        let fixture = try Fixture()
        let scope = fixture.scope(for: fixture.unrelatedTurn)
        let jiraBehavior = "Use Jira to review issues before answering."
        #expect(!scope.resolver.effectiveSnapshots.contains { $0.behaviorInstructions == jiraBehavior })
        #expect(scope.reachableBehaviorInstructions.contains(jiraBehavior))
    }

    /// The launch guard reads `ASTRA_BROWSER_URL`, which is injected from the
    /// reachable set, while the *requirement* comes from the narrated set. A
    /// Copilot build with neither shell nor browser MCP therefore aborted turns
    /// that never asked for a browser, purely because the workspace had a Shelf
    /// endpoint bound. Offered routes attach where the transport can carry them
    /// and are dropped where it cannot.
    @Test("An offered browser bridge is dropped, not blocked, where nothing can carry it")
    func offeredBrowserBridgeIsDroppedNotBlockedWhereNothingCanCarryIt() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-offered-browser-\(UUID().uuidString)", isDirectory: true)
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Offered Browser", primaryPath: root.path)
        // Enabled in the workspace and never mentioned by the turn: reachable,
        // so the endpoint is injected, and unnarrated, so nothing requires it.
        let browserTool = LocalTool(
            name: "ASTRA Browser",
            toolDescription: "Drive a browser session",
            command: "astra-browser"
        )
        browserTool.workspace = workspace
        let task = AgentTask(
            title: "Write a recipe",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace,
            model: "gpt-5",
            runtime: .copilotCLI
        )
        for model in [workspace, browserTool, task] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: nil,
            currentTitle: nil,
            taskID: task.id,
            isPresented: false,
            isEnabled: true
        )

        // "/bin/copilot-not-present" has no --additional-mcp-config, so this
        // build has no browser MCP tool either; Copilot has no shell.
        func plan(requiresBrowserControl: Bool) -> AgentRuntimeProcessLaunchPlan {
            AgentRuntimeAdapterRegistry
                .adapter(for: .copilotCLI)
                .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                    prompt: task.goal,
                    task: task,
                    workspacePath: workspace.primaryPath,
                    executablePath: "/bin/copilot-not-present",
                    providerHomeDirectory: root.appendingPathComponent("copilot-home").path,
                    permissionPolicy: .restricted,
                    executionPolicy: .default,
                    permissionManifest: nil,
                    timeoutSeconds: 30,
                    phase: "run",
                    contextText: task.goal,
                    runtimeRequirements: TaskRuntimeRequirementSet(
                        hostControlTools: [],
                        requiresDockerWorkspaceShell: false,
                        requiresBrowserControl: requiresBrowserControl
                    )
                ))
        }

        let offered = plan(requiresBrowserControl: false)
        #expect(offered.environment["ASTRA_BROWSER_URL"] == nil)
        #expect(offered.commandPlannedFields["browser_bridge_attached"] == "false")
        #expect(offered.commandPlannedFields["browser_bridge_launch_block_reason"] == "none")
        #expect(BrowserBridgeRuntimeLaunchGuard.launchBlock(for: offered) == nil)

        // A turn that does need the browser still fails loudly: the run cannot
        // do what it was asked to do, and saying so is the correct answer.
        let required = plan(requiresBrowserControl: true)
        #expect(required.environment["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
        #expect(required.commandPlannedFields["browser_bridge_launch_block_reason"]
            == BrowserBridgeRuntimeLaunchGuard.missingBrowserControlToolReason)
        #expect(BrowserBridgeRuntimeLaunchGuard.launchBlock(for: required) != nil)
    }

    /// The permission allowlist is built from `reachableLocalTools`, so an
    /// enabled tool is callable on every turn. The prompt named only the
    /// narrated subset, which left the agent holding a permitted command it had
    /// never been told about - indistinguishable, from inside the run, from not
    /// having the tool at all.
    @Test("A reachable local tool the turn never names still gets its command named")
    func reachableLocalToolTheTurnNeverNamesStillGetsItsCommandNamed() throws {
        let fixture = try Fixture()
        let tool = LocalTool(
            name: "Registry Exporter",
            toolDescription: "Export instrument rows from the study registry",
            command: "registry-export",
            arguments: "--format csv"
        )
        tool.workspace = fixture.workspace
        fixture.context.insert(tool)
        try fixture.context.save()

        let scope = fixture.scope(for: fixture.unrelatedTurn)
        #expect(!scope.localTools.contains { $0.id == tool.id })
        #expect(scope.reachableLocalTools.contains { $0.id == tool.id })

        // `AgentPolicyAdapters` and `ProviderLaunchSignatureService` both build
        // from `reachableLocalTools`, so the run is allowlisted for this command
        // and its signature records it. Staying silent about it in the prompt is
        // therefore a lie about the run, not a restriction on it.
        let prompt = AgentPromptBuilder.buildPrompt(for: fixture.task)
        #expect(prompt.contains("Also available and callable in this run"))
        #expect(prompt.contains("registry-export --format csv"))
        // Named, not re-narrated: the pruned description stays pruned.
        #expect(!prompt.contains("Export instrument rows from the study registry"))
    }

    /// `ASTRA_MAIL_REGISTRY_PATH` is not a route, it is a credential pointer:
    /// the registry it names hands the helper the Keychain service holding the
    /// mailbox tokens, which the helper reads with `/usr/bin/security` - outside
    /// the connector projection, so nothing downstream can withhold it.
    /// Connector preflight walks only the narrated set, so injecting this from
    /// the reachable tier would let a turn about something else perform
    /// authenticated mailbox reads the user was never asked about.
    @Test("An offered-only mail connector gets no registry pointer until it is approved")
    func offeredOnlyMailConnectorGetsNoRegistryPointerUntilApproved() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "mail-tier", primaryPath: NSTemporaryDirectory())
        let mail = Connector(
            name: "Stanford Outlook Mail",
            serviceType: StanfordOutlookMail.serviceType,
            connectorDescription: "Read Stanford mail through Microsoft Graph",
            baseURL: StanfordOutlookMail.graphBaseURL,
            authMethod: StanfordOutlookMail.authMethod
        )
        mail.isGlobal = true
        workspace.enabledGlobalConnectorIDs = [mail.id.uuidString]
        let unrelatedTurn = "Bake a chocolate sponge cake and write the recipe"
        let task = AgentTask(title: "Recipe", goal: unrelatedTurn, workspace: workspace)
        for model in [workspace, mail, task] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()

        func registryPath(contextText: String, grants: [PermissionGrant] = []) -> String? {
            AgentRuntimeProcessRunner.scopedEnvironmentVariables(
                for: task,
                contextText: contextText,
                executionPolicy: AgentRuntimeExecutionPolicy(permissionGrantsOverride: grants)
            )["ASTRA_MAIL_REGISTRY_PATH"]
        }

        // Enabled in the workspace and unnamed by the turn: offered. Offered
        // widens what a run may reach, and consent is not one of those things.
        let offeredScope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: unrelatedTurn
        ).providerLaunch
        #expect(offeredScope.reachableConnectors.contains { $0.id == mail.id })
        #expect(!offeredScope.connectors.contains { $0.id == mail.id })
        #expect(registryPath(contextText: unrelatedTurn) == nil)

        // Narrated: preflight walks this set, so the first-use approval was
        // raised and the pointer is the run doing what it was asked to do.
        let mailTurn = "read my Stanford Outlook Mail inbox"
        #expect(TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: mailTurn
        ).providerLaunch.connectors.contains { $0.id == mail.id })
        #expect(registryPath(contextText: mailTurn) == StanfordOutlookMail.registryURL.path)

        // An approved credential grant is the same consent by another route, so
        // the offered tier has to carry it - otherwise approving the card leaves
        // the helper without the pointer the approval was about.
        let grant = PermissionGrant.credential(
            label: "connector:\(mail.id.uuidString):\(StanfordOutlookMail.accessTokenKey)"
        )
        #expect(registryPath(contextText: unrelatedTurn, grants: [grant])
            == StanfordOutlookMail.registryURL.path)
        // Including where the scope was captured before the approval existed,
        // which is the seam this guard actually sits on.
        #expect(AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: task,
            capabilityScope: offeredScope,
            contextText: unrelatedTurn,
            executionPolicy: AgentRuntimeExecutionPolicy(permissionGrantsOverride: [grant])
        )["ASTRA_MAIL_REGISTRY_PATH"] == StanfordOutlookMail.registryURL.path)
    }

    /// Preflight is the launch-blocking surface, and it reads the browser MCP
    /// server out of the launch environment - where `ASTRA_BROWSER_URL` arrives
    /// from the reachable set. A workspace with a bound Shelf endpoint therefore
    /// materializes this server on turns that never mention a browser, and
    /// letting a missing `astra-browser` helper reach `mcpIssues` from there
    /// aborts an unrelated Claude run over a route it never asked for.
    @Test("A missing browser helper blocks only the turn that asked for a browser")
    func missingBrowserHelperBlocksOnlyTheTurnThatAskedForABrowser() throws {
        let fixture = try BrowserFixture(runtime: .claudeCode)
        defer { fixture.tearDown() }

        func preflight(contextText: String) throws -> AgentRuntimeLaunchPreflightResult {
            let task = try fixture.makeTask(goal: contextText)
            let run = TaskRun(task: task)
            fixture.context.insert(run)
            try fixture.context.save()
            return AgentRuntimeLaunchPreflight.preflightCapabilitiesBeforeLaunchResult(
                task: task,
                run: run,
                modelContext: fixture.context,
                phase: "run",
                contextText: contextText,
                mcpIsExecutableFile: { $0 != BrowserFixture.helperPath },
                runtimeProfile: { .defaultProfile(for: $0) }
            )
        }

        let offered = try preflight(contextText: BrowserFixture.unrelatedTurn)
        #expect(offered.didPass)
        #expect(offered.status == .capabilityRuntimeResourcesPassed)

        // A turn that does need the browser still fails loudly, because now the
        // run cannot do what it was asked to do.
        let required = try preflight(contextText: BrowserFixture.browserTurn)
        #expect(!required.didPass)
        #expect(required.reason == "mcp_server_executable_missing")
        #expect(required.detail?.contains(BrowserBridgeMCPProjection.serverID) == true)
    }

    /// The launch plan is a durable record of what the launch attached, so the
    /// two browser tiers cannot collapse into one entry. Recording the offered
    /// tier as required made Run Activity assert a required, configured resource
    /// on runs where the adapter had dropped the bridge for lack of a transport.
    @Test("The launch plan records an offered browser bridge as offered, and only where it lands")
    func launchPlanRecordsOfferedBrowserBridgeAsOfferedAndOnlyWhereItLands() throws {
        let fixture = try BrowserFixture(runtime: .claudeCode)
        defer { fixture.tearDown() }

        func browserRequirement(
            contextText: String,
            runtime: AgentRuntimeID,
            profile: AgentRuntimeCapabilityProfile
        ) -> RuntimeProviderRequirement? {
            TaskLaunchResourceResolver.resolve(
                task: fixture.task,
                runID: UUID(),
                runtime: runtime,
                phase: .run,
                prompt: contextText,
                contextText: contextText,
                workspacePath: fixture.workspace.primaryPath,
                executionEnvironment: .host,
                connectorSecretStore: MockSecretStore(),
                runtimeCapabilityProfile: profile
            )
            .providerRequirements
            .first { $0.capability == "browser_bridge" }
        }

        // Claude has a shell, so the offered bridge is attached - and recorded
        // as what it is: available, not asked for.
        let offered = browserRequirement(
            contextText: BrowserFixture.unrelatedTurn,
            runtime: .claudeCode,
            profile: .defaultProfile(for: .claudeCode)
        )
        #expect(offered != nil)
        #expect(offered?.required == false)

        // Copilot without --additional-mcp-config has neither shell nor browser
        // MCP, so the launch drops the offered bridge. A plan entry here would
        // describe a route the process never received.
        #expect(browserRequirement(
            contextText: BrowserFixture.unrelatedTurn,
            runtime: .copilotCLI,
            profile: .copilotProfile(supportsAdditionalMCPConfig: false)
        ) == nil)

        // Required is unchanged on every runtime: a turn that asks for the
        // browser is recorded as requiring it, and the launch guard - not this
        // plan - is what refuses the run.
        let required = browserRequirement(
            contextText: BrowserFixture.browserTurn,
            runtime: .copilotCLI,
            profile: .copilotProfile(supportsAdditionalMCPConfig: false)
        )
        #expect(required?.required == true)
    }

    /// Naming an offered route the launch removed is the inversion the offered
    /// tier exists to prevent: the prompt tells the agent `astra-browser` is
    /// callable, the adapter strips the bridge for lack of a transport, and the
    /// command fails with neither surface able to say why.
    @Test("The prompt names an offered browser bridge only where the launch can attach it")
    func promptNamesOfferedBrowserBridgeOnlyWhereTheLaunchCanAttachIt() throws {
        let fixture = try BrowserFixture(runtime: .copilotCLI)
        defer { fixture.tearDown() }

        func prompt(supportsAdditionalMCPConfig: Bool) -> String {
            AgentPromptBuilder.buildPrompt(
                for: fixture.task,
                executionPolicy: AgentRuntimeExecutionPolicy(
                    runtimeCapabilityProfile: .copilotProfile(
                        supportsAdditionalMCPConfig: supportsAdditionalMCPConfig
                    )
                )
            )
        }

        // The offered list names a tool by command, which is the claim under
        // test - the Shelf session block elsewhere in the prompt describes the
        // bridge in runtime-conditional terms and is not this tier.
        let offeredEntry = "- Shelf Browser Control: `\(BrowserBridgeMCPProjection.toolCommand)`"
        // With --additional-mcp-config the launch carries the bridge over the
        // browser MCP tool, so the offered list is telling the truth.
        #expect(prompt(supportsAdditionalMCPConfig: true).contains(offeredEntry))
        // Without it this Copilot build has no shell and no browser MCP, so the
        // launch drops the bridge and the prompt must not advertise it.
        #expect(!prompt(supportsAdditionalMCPConfig: false).contains(offeredEntry))
    }

    /// A workspace whose Shelf browser is open and bound to an endpoint. That
    /// alone makes the bridge reachable on *every* turn, so `unrelatedTurn`
    /// leaves it offered - attached, and named by nothing - while `browserTurn`
    /// shares wording with the Shelf browser tool and narrates it.
    @MainActor
    private struct BrowserFixture {
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let task: AgentTask
        let root: URL

        static let unrelatedTurn = "Bake a chocolate sponge cake and write the recipe"
        static let browserTurn = "control the Shelf browser session and verify the outcome"
        static let helperPath = (RuntimePathResolver.astraToolsPath as NSString)
            .appendingPathComponent(BrowserBridgeMCPProjection.toolCommand)

        init(runtime: AgentRuntimeID) throws {
            ShelfBrowserBridgeRegistry.shared.reset()
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("astra-offered-browser-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            workspace = Workspace(name: "Offered Browser", primaryPath: root.path)
            context.insert(workspace)
            task = AgentTask(
                title: "Write a recipe",
                goal: Self.unrelatedTurn,
                workspace: workspace,
                model: "gpt-5",
                runtime: runtime
            )
            context.insert(task)
            try context.save()
            bindShelf(to: task)
        }

        /// A second task on the same workspace, for the surfaces that read the
        /// turn off the task rather than off a `contextText` argument.
        func makeTask(goal: String) throws -> AgentTask {
            let turnTask = AgentTask(
                title: "Turn",
                goal: goal,
                workspace: workspace,
                model: task.model,
                runtime: task.resolvedRuntimeID
            )
            turnTask.status = .running
            context.insert(turnTask)
            try context.save()
            bindShelf(to: turnTask)
            return turnTask
        }

        func tearDown() {
            ShelfBrowserBridgeRegistry.shared.reset()
            try? FileManager.default.removeItem(at: root)
        }

        private func bindShelf(to task: AgentTask) {
            ShelfBrowserBridgeRegistry.shared.update(
                endpoint: "http://127.0.0.1:49152",
                currentURL: nil,
                currentTitle: nil,
                taskID: task.id,
                isPresented: true,
                isEnabled: true
            )
        }
    }

    /// One enabled Jira connector, one turn that names it and one that does not.
    /// `includingREDCap` adds a second broker-owned connector no turn here ever
    /// names, which is what separates "reachable" from "narrated" for the two
    /// brokered surfaces below.
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let store: MockSecretStore
        let workspace: Workspace
        let task: AgentTask
        let jiraConnector: Connector
        let redcapConnector: Connector?
        let jiraTurn = "check the open Jira issues for this sprint"
        let unrelatedTurn = "Bake a chocolate sponge cake and write the recipe"
        static let jiraSecret = "secret-token-value"
        static let redcapSecret = "redcap-secret-value"

        /// The provider-launch scope this fixture's task resolves to for `turn`.
        func scope(for turn: String) -> TaskCapabilityPromptScope {
            TaskCapabilityResolutionSnapshot.capture(
                for: task,
                providerLaunchContextText: turn,
                secretStore: store
            ).providerLaunch
        }

        init(includingREDCap: Bool = false) throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            store = MockSecretStore()
            workspace = Workspace(name: "offered-tier", primaryPath: NSTemporaryDirectory())
            let skill = Skill(
                name: "Jira Agent",
                skillDescription: "Review support issues and ticket queues",
                allowedTools: ["Read", "Bash"],
                behaviorInstructions: "Use Jira to review issues before answering."
            )
            skill.isGlobal = true
            let connector = Connector(
                name: "Jira-new",
                serviceType: "jira",
                connectorDescription: "Atlassian Jira REST API v3",
                baseURL: "https://example.atlassian.net",
                authMethod: "basic"
            )
            connector.isGlobal = true
            connector.skill = skill
            connector.credentialKeys = ["JIRA_API_TOKEN"]
            store.save(
                key: "JIRA_API_TOKEN",
                value: Self.jiraSecret,
                entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
                label: nil
            )
            jiraConnector = connector
            var models: [any PersistentModel] = [workspace, skill, connector]
            var enabledConnectorIDs = [connector.id.uuidString]

            if includingREDCap {
                // No skill and no word this suite's turns can land on, so it is
                // reachable through workspace enablement alone.
                let redcap = Connector(
                    name: "Registry Export",
                    serviceType: "redcap",
                    connectorDescription: "REDCap instrument export endpoint",
                    baseURL: "https://redcap.example.edu/api/",
                    authMethod: "token"
                )
                redcap.isGlobal = true
                redcap.credentialKeys = ["REDCAP_API_TOKEN"]
                store.save(
                    key: "REDCAP_API_TOKEN",
                    value: Self.redcapSecret,
                    entityID: KeychainSecretStore.connectorEntityID(for: redcap.id),
                    label: nil
                )
                redcapConnector = redcap
                models.append(redcap)
                enabledConnectorIDs.append(redcap.id.uuidString)
            } else {
                redcapConnector = nil
            }

            workspace.enabledGlobalConnectorIDs = enabledConnectorIDs
            task = AgentTask(title: "Support tickets", goal: unrelatedTurn, workspace: workspace)
            models.append(task)
            for model in models {
                context.insert(model)
            }
            try context.save()
        }
    }
}
