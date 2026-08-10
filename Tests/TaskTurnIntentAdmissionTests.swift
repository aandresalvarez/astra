import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Turn-scoped runtime admission")
@MainActor
struct TaskTurnIntentAdmissionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Stale Jira history cannot block an unrelated Cursor continuation")
    func staleJiraHistoryDoesNotBlockCursorContinuation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Long-lived task", primaryPath: "/tmp/astra-turn-intent")
        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Read Jira tickets",
            behaviorInstructions: "Always use ASTRA host-control MCP tool mcp__astra_host__jira; do not use Bash."
        )
        let jira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Jira issues",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.skill = jiraSkill
        jira.workspace = workspace

        let outlookSkill = Skill(
            name: "Stanford Outlook",
            skillDescription: "Read Outlook mail"
        )
        let outlook = Connector(
            name: "Stanford Outlook",
            serviceType: "outlook",
            connectorDescription: "Microsoft 365 mailbox",
            baseURL: "https://outlook.office.com",
            authMethod: "bearer"
        )
        outlook.credentialKeys = ["OUTLOOK_TOKEN"]
        outlook.skill = outlookSkill
        outlook.workspace = workspace

        let task = AgentTask(
            title: "Old Jira task",
            goal: "Review STAR-11866 in Jira and email the result",
            workspace: workspace,
            runtime: .cursorCLI
        )
        task.skills = [jiraSkill, outlookSkill]
        context.insert(workspace)
        context.insert(jiraSkill)
        context.insert(jira)
        context.insert(outlookSkill)
        context.insert(outlook)
        context.insert(task)

        let oldTurn = TaskEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Review STAR-11866 in Jira and email the result"
        )
        oldTurn.timestamp = Date(timeIntervalSince1970: 1)
        let currentObjective = TaskEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Write the SSH SOP and general runtime guidelines."
        )
        currentObjective.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(oldTurn)
        context.insert(currentObjective)
        try context.save()

        let intent = TaskTurnIntentResolver.capture(
            for: task,
            sourceEventID: nil,
            acceptedTurn: "try again",
            includeTaskInputs: false
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: """
            Historical prompt mentions Jira, JIRA_EMAIL, JIRA_API_TOKEN, Outlook,
            and https://stanfordmed.atlassian.net.
            """,
            turnIntentSnapshot: intent,
            runtime: .cursorCLI,
            exposeAllConnectorCredentials: true
        )

        #expect(intent.inheritedTurn == "Write the SSH SOP and general runtime guidelines.")
        #expect(snapshot.providerLaunch.connectors.isEmpty)
        #expect(snapshot.connectorCredentialExposurePolicy == .none)

        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeAttached: false
        )
        let resolution = TaskRuntimeCompatibilityService.resolve(
            requestedRuntime: .cursorCLI,
            defaultRuntime: .claudeCode,
            requirements: requirements,
            candidateRuntimes: [.cursorCLI, .claudeCode],
            respectExplicitRuntimeChoice: true,
            profile: {
                AgentRuntimeCapabilityProfileService.profile(
                    for: $0,
                    executablePath: "/usr/bin/true"
                )
            },
            isRuntimeUsable: { _ in true }
        )
        #expect(requirements.isEmpty)
        #expect(resolution.selectedRuntime == .cursorCLI)
        #expect(resolution.launchBlock == nil)
    }

    @Test("Referential intent skips retracted turns and keeps substantive continuations current")
    func referentialIntentSkipsRetractedTurns() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Intent", goal: "Initial objective")
        context.insert(task)

        let retained = TaskEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Write the SSH operating procedure."
        )
        retained.timestamp = Date(timeIntervalSince1970: 1)
        let retracted = TaskEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "Read ASTRA-123 in Jira."
        )
        retracted.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(retained)
        context.insert(retracted)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: retracted.id,
            sequence: 1,
            state: .cancelled
        )
        context.insert(request)
        try context.save()

        let retry = TaskTurnIntentResolver.capture(
            for: task,
            sourceEventID: nil,
            acceptedTurn: "try again",
            includeTaskInputs: false
        )
        #expect(retry.isReferential)
        #expect(retry.inheritedTurn == "Write the SSH operating procedure.")

        let substantive = TaskTurnIntentResolver.capture(
            for: task,
            sourceEventID: nil,
            acceptedTurn: "continue with the Jira incident analysis",
            includeTaskInputs: false
        )
        #expect(!substantive.isReferential)
        #expect(substantive.inheritedTurn == nil)
    }

    @Test("Explicit Jira intent stays brokered and uses Cursor's CLI relay")
    func explicitJiraIntentUsesBrokerCompatibility() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira task", primaryPath: "/tmp/astra-jira-intent")
        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Read Jira tickets",
            behaviorInstructions: "Always use ASTRA host-control MCP tool mcp__astra_host__jira; do not use Bash."
        )
        let jira = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira issues",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.skill = jiraSkill
        jira.workspace = workspace
        let task = AgentTask(
            title: "Jira",
            goal: "Read STAR-11866 in Jira",
            workspace: workspace,
            runtime: .cursorCLI
        )
        task.skills = [jiraSkill]
        context.insert(workspace)
        context.insert(jiraSkill)
        context.insert(jira)
        context.insert(task)
        try context.save()

        let intent = TaskTurnIntentSnapshot(
            taskID: task.id,
            sourceEventID: nil,
            acceptedTurn: "Read STAR-11866 in Jira"
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: task.goal,
            turnIntentSnapshot: intent,
            runtime: .cursorCLI
        )
        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeAttached: false
        )

        #expect(snapshot.providerLaunch.connectors.map(\.id) == [jira.id])
        #expect(snapshot.connectorCredentialExposurePolicy == .none)
        #expect(requirements.hostControlTools == ["jira"])
        #expect(TaskRuntimeCompatibilityService.incompatibilities(
            runtime: .cursorCLI,
            requirements: requirements,
            profile: AgentRuntimeCapabilityProfileService.profile(
                for: .cursorCLI,
                executablePath: "/usr/bin/true"
            ),
            isRuntimeUsable: true
        ).isEmpty)
        #expect(
            AgentRuntimeCapabilityProfile.defaultProfile(for: .cursorCLI)
                .usesHostControlCLIRelay
        )
    }

    /// Regression for task B129DA53: approving a Jira credential prompt
    /// "for similar requests in this task" resumed the run with the Jira
    /// connector pruned out of scope, so `mcp__astra_host__jira` failed with
    /// "No Jira connector is projected into ASTRA_CONNECTORS". The resume
    /// envelope's generated prose had become the turn's activation text, and it
    /// shares no token with Jira — while unrelated capabilities matched it on
    /// generic words. An approval must never subtract authority.
    @Test("Approving a credential prompt keeps the approved connector in the resumed run's scope")
    func permissionResumeKeepsApprovedConnectorInScope() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira resume", primaryPath: "/tmp/astra-permission-resume")

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Read Jira tickets",
            behaviorInstructions: "Always use ASTRA host-control MCP tool mcp__astra_host__jira; do not use Bash."
        )
        let jira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Jira issues",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.skill = jiraSkill
        jira.workspace = workspace

        // The decoy that actually won in production: its prose shares generic
        // tokens ("run", "task", "operation") with the approval sentence.
        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Run Google Cloud operations for this task",
            behaviorInstructions: "Always use ASTRA host-control MCP tool mcp__astra_host__gcloud to run the requested operation for this task."
        )
        let gcloud = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "Run cloud operations for this task",
            baseURL: "https://cloudresourcemanager.googleapis.com",
            authMethod: "bearer"
        )
        gcloud.skill = gcloudSkill
        gcloud.workspace = workspace

        let task = AgentTask(
            title: "Jira tickets",
            goal: "Answer questions about the user's work",
            workspace: workspace,
            runtime: .claudeCode
        )
        task.skills = [jiraSkill, gcloudSkill]
        context.insert(workspace)
        context.insert(jiraSkill)
        context.insert(jira)
        context.insert(gcloudSkill)
        context.insert(gcloud)
        context.insert(task)

        let userTurn = TaskEvent(
            task: task,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "can you see my open tickets in Jira SS project? user alvaro1?"
        )
        userTurn.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(userTurn)
        try context.save()

        // Exactly what approveSimilarRuntimePermissionForTask submits.
        let grants: [PermissionGrant] = [
            .credential(label: "JIRA_API_TOKEN"),
            .credential(label: "JIRA_EMAIL")
        ]
        let resumeMessage = PermissionBroker.resumeMessage(
            providerID: .claudeCode,
            grants: grants,
            fallback: nil,
            scopeDescription: "task-scoped runtime permission for similar requests in this task"
        )
        #expect(!resumeMessage.lowercased().contains("jira"))

        guard case .success(let submission) = ExecutionRequestSubmissionService.submitPermissionResume(
            message: resumeMessage,
            executionPolicy: .default,
            for: task,
            into: context
        ) else {
            Issue.record("Expected the permission resume to persist")
            return
        }

        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        let intent = try #require(request.executionPolicySnapshot?.turnIntentSnapshot)
        #expect(intent.activationText == "can you see my open tickets in Jira SS project? user alvaro1?")

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: resumeMessage,
            turnIntentSnapshot: intent,
            runtime: .claudeCode
        )
        #expect(snapshot.providerLaunch.connectors.map(\.id).contains(jira.id))

        // The connector must survive all the way to the run-scoped broker, which
        // is what actually answers mcp__astra_host__jira.
        let requiredTools = HostControlPlaneMCPProjection.requiredToolNames(
            capabilityScope: snapshot.providerLaunch
        )
        #expect(requiredTools.contains("jira"))

        let brokeredTools = Set(requiredTools)
        let brokeredConnectors = snapshot.providerLaunch.connectors.filter {
            HostControlPlaneMCPProjection.brokerOwnsConnectorConfiguration($0.serviceType)
                && HostControlPlaneMCPProjection.connectorToolName($0.serviceType)
                    .map(brokeredTools.contains) == true
        }
        #expect(brokeredConnectors.map(\.id) == [jira.id])
    }

    @Test("Candidate admission is invariant across requested runtime and evaluation order")
    func candidateAdmissionIsOrderInvariant() throws {
        let fixture = try makeJiraAdmissionFixture()
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let policy = AgentRuntimeExecutionPolicy.default.withTurnIntentSnapshot(intent)
        let configuration = runtimeConfiguration(
            runtimes: [.cursorCLI, .openCodeCLI, .antigravityCLI, .claudeCode, .codexCLI],
            defaultRuntime: .claudeCode
        )

        let first = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .cursorCLI,
            runtimeConfiguration: configuration,
            executionPolicy: policy,
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.cursorCLI, .openCodeCLI, .antigravityCLI, .claudeCode, .codexCLI],
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { true }
        )
        let second = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .codexCLI,
            runtimeConfiguration: configuration,
            executionPolicy: policy,
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.codexCLI, .claudeCode, .antigravityCLI, .openCodeCLI, .cursorCLI],
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { true }
        )

        for runtime in [
            AgentRuntimeID.cursorCLI,
            .openCodeCLI,
            .antigravityCLI,
            .claudeCode,
            .codexCLI
        ] {
            let lhs = try #require(first.candidates[runtime])
            let rhs = try #require(second.candidates[runtime])
            #expect(lhs.contractDigest == rhs.contractDigest)
            #expect(lhs.isEligible == rhs.isEligible)
            #expect(lhs.requirements == rhs.requirements)
            #expect(
                LaunchResourceContract(plan: lhs.launchResourcePlan).resources
                    == LaunchResourceContract(plan: rhs.launchResourcePlan).resources
            )
        }
        #expect(first.candidates[.cursorCLI]?.isEligible == true)
        #expect(first.candidates[.openCodeCLI]?.isEligible == true)
        #expect(first.candidates[.antigravityCLI]?.isEligible == true)
        #expect(first.candidates[.claudeCode]?.isEligible == true)
        #expect(first.candidates[.codexCLI]?.isEligible == true)
        for runtime in [
            AgentRuntimeID.cursorCLI,
            .openCodeCLI,
            .antigravityCLI
        ] {
            #expect(first.candidates[runtime]?.launchResourcePlan.controlPlaneResources.contains {
                $0.capability == "jira" && $0.placement == "host_control_cli_broker"
            } == true)
        }
        #expect(first.candidates[.claudeCode]?.launchResourcePlan.controlPlaneResources.contains {
            $0.capability == "jira" && $0.placement == "host_control_mcp_broker"
        } == true)
    }

    @Test("Preview state is signature-specific and admission preserves the requested provider")
    func previewStatePreservesRequestedProvider() throws {
        let fixture = try makeJiraAdmissionFixture()
        fixture.task.runtimeExplicitlySelected = false
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let snapshot = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .cursorCLI,
            runtimeConfiguration: runtimeConfiguration(
                runtimes: [.cursorCLI, .claudeCode],
                defaultRuntime: .claudeCode
            ),
            executionPolicy: .default.withTurnIntentSnapshot(intent),
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.cursorCLI, .claudeCode],
            isRuntimeUsable: { runtime, _ in runtime == .claudeCode },
            isHostControlBrokerAvailable: { true }
        )
        let state = RuntimeEligibilityPreviewState.evaluated(
            signature: "current",
            snapshot: snapshot
        )
        let pending = RuntimeEligibilityPreviewState.pending(signature: "current")
        let unavailable = RuntimeEligibilityPreviewState.evaluated(
            signature: "current",
            snapshot: nil
        )

        #expect(state.currentSnapshot(for: "stale") == nil)
        #expect(pending.isPending(for: "current"))
        #expect(!pending.isPending(for: "stale"))
        #expect(unavailable.isUnavailable(for: "current"))
        let current = try #require(state.currentSnapshot(for: "current"))
        #expect(current.requestedRuntime == .cursorCLI)
        #expect(current.selectedRuntime == .cursorCLI)
        #expect(current.candidates[.cursorCLI]?.isEligible == false)
        #expect(current.suggestedRuntime == .claudeCode)
        let readiness: [AgentRuntimeID: RuntimeReadinessState] = [
            .cursorCLI: .ready,
            .claudeCode: .ready
        ]
        #expect(!RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: true,
            runtime: .cursorCLI,
            readinessStates: readiness,
            previewState: state,
            signature: "current"
        ))
        #expect(RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: true,
            runtime: .claudeCode,
            readinessStates: readiness,
            previewState: state,
            signature: "current"
        ))
        #expect(!RuntimeEligibilitySubmissionPolicy.canExecute(
            hasInput: true,
            runtime: .claudeCode,
            readinessStates: readiness,
            previewState: pending,
            signature: "current"
        ))
        #expect(RuntimeEligibilitySubmissionPolicy.providersThatCanExecute(
            [.cursorCLI, .claudeCode],
            readinessStates: readiness,
            previewState: state,
            signature: "current"
        ) == [.claudeCode])
    }

    @Test("Admission blocks host-control candidates when the broker helper is unavailable")
    func admissionRequiresBrokerHelperReadiness() throws {
        let fixture = try makeJiraAdmissionFixture()
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let result = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .cursorCLI,
            runtimeConfiguration: runtimeConfiguration(
                runtimes: [.cursorCLI],
                defaultRuntime: .cursorCLI
            ),
            executionPolicy: .default.withTurnIntentSnapshot(intent),
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.cursorCLI],
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { false }
        )

        #expect(result.candidates[.cursorCLI]?.incompatibilities.contains(
            .hostControlBrokerUnavailable
        ) == true)
        #expect(result.launchBlock != nil)
    }

    @Test("Metadata preview and authoritative Jira planning share one contract")
    func metadataPreviewMatchesAuthoritativeJiraContract() throws {
        let fixture = try makeJiraAdmissionFixture()
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Search Jira for project ASTRA"
        )
        let policy = AgentRuntimeExecutionPolicy.default.withTurnIntentSnapshot(intent)
        let configuration = runtimeConfiguration(
            runtimes: [.claudeCode],
            defaultRuntime: .claudeCode
        )
        let preview = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .claudeCode,
            runtimeConfiguration: configuration,
            executionPolicy: policy,
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.claudeCode],
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { true }
        )
        let authoritative = TaskLaunchAdmissionService.evaluate(
            task: fixture.task,
            intent: intent,
            requestedRuntime: .claudeCode,
            runtimeConfiguration: configuration,
            executionPolicy: policy,
            fallbackPermissionPolicy: .interactive,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            phase: .run,
            candidateRuntimes: [.claudeCode],
            secretStore: StaticAdmissionSecretStore(values: [
                "JIRA_EMAIL": "person@example.edu",
                "JIRA_API_TOKEN": "authoritative-token"
            ]),
            isRuntimeUsable: { _, _ in true },
            isHostControlBrokerAvailable: { true }
        )

        let previewCandidate = try #require(preview.candidates[.claudeCode])
        let authoritativeCandidate = try #require(authoritative.candidates[.claudeCode])
        #expect(previewCandidate.contractDigest == authoritativeCandidate.contractDigest)
        #expect(
            LaunchResourceContract(plan: previewCandidate.launchResourcePlan).resources
                == LaunchResourceContract(plan: authoritativeCandidate.launchResourcePlan).resources
        )
        #expect(authoritativeCandidate.launchResourcePlan.credentialGrants.isEmpty)
        #expect(authoritativeCandidate.launchResourcePlan.environmentGrants.allSatisfy {
            $0.sensitivity != .credential
        })
    }

    @Test("Brokered Jira values never enter the provider environment")
    func brokeredJiraValuesStayOutOfProviderEnvironment() throws {
        let fixture = try makeJiraAdmissionFixture()
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let labels = fixture.connector.credentialKeys.map {
            ConnectorRuntimeProjection.credentialLabel(for: fixture.connector, key: $0)
        }
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: intent.acceptedTurn,
            additionalCredentialGrants: labels.map { .credential(label: $0) },
            turnIntentSnapshot: intent,
            runtime: .claudeCode,
            secretStore: StaticAdmissionSecretStore(values: [
                "JIRA_EMAIL": "person@example.edu",
                "JIRA_API_TOKEN": "provider-must-not-see-this"
            ])
        )
        let requirements = TaskRuntimeRequirementSet.derive(
            task: fixture.task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeAttached: false
        )
        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: fixture.task,
            capabilityScope: snapshot.providerLaunch,
            contextText: intent.acceptedTurn,
            runtimeRequirements: requirements
        )

        #expect(requirements.hostControlTools == ["jira"])
        #expect(!environment.values.contains("person@example.edu"))
        #expect(!environment.values.contains("provider-must-not-see-this"))
        #expect(!environment.keys.contains { $0.contains("JIRA_EMAIL") || $0.contains("JIRA_API_TOKEN") })
    }

    @Test("Host-control broker endpoint replaces connector environment delivery")
    func hostControlBrokerEndpointReplacesConnectorEnvironment() throws {
        let fixture = try makeJiraAdmissionFixture()
        let intent = TaskTurnIntentSnapshot(
            taskID: fixture.task.id,
            sourceEventID: nil,
            acceptedTurn: "Read ASTRA-123 in Jira"
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: intent.acceptedTurn,
            turnIntentSnapshot: intent,
            runtime: .claudeCode
        )
        let runID = UUID()
        let prepared = HostControlBrokerSessionRegistry.shared.prepare(
            task: fixture.task,
            runID: runID,
            capabilityScope: snapshot.providerLaunch,
            requiredTools: ["jira"],
            currentDirectory: "/tmp",
            expectedHelperPath: try builtHostControlHelperPath()
        )
        defer {
            HostControlBrokerSessionRegistry.shared.stop(taskID: fixture.task.id, runID: runID)
        }
        #expect(prepared)

        let environment = HostControlPlaneMCPProjection.environmentVariables(
            task: fixture.task,
            environment: .host,
            currentDirectory: "/tmp",
            runID: runID,
            taskEnvironment: [
                "JIRA_EMAIL": "person@example.edu",
                "JIRA_API_TOKEN": "provider-must-not-see-this"
            ],
            capabilityScope: snapshot.providerLaunch,
            precomputedRuntimeRequirements: TaskRuntimeRequirementSet(
                hostControlTools: ["jira"],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            )
        )

        let socketPath = try #require(
            environment[HostControlBrokerIPC.endpointEnvironmentKey]
        )
        #expect(try HostControlBrokerIPC.validatedSocketPath(socketPath) == socketPath)
        #expect(FileManager.default.fileExists(atPath: socketPath))
        #expect(environment["JIRA_EMAIL"] == nil)
        #expect(environment["JIRA_API_TOKEN"] == nil)
        #expect(!environment.values.contains("provider-must-not-see-this"))
        HostControlBrokerSessionRegistry.shared.stop(taskID: fixture.task.id, runID: runID)
        #expect(
            HostControlBrokerSessionRegistry.shared.endpoint(taskID: fixture.task.id, runID: runID) == nil
        )
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("Broker preparation fails before readiness when the relay helper is unavailable")
    func brokerPreparationRequiresExecutableHelper() throws {
        let fixture = try makeJiraAdmissionFixture()
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: "Read ASTRA-123 in Jira",
            turnIntentSnapshot: TaskTurnIntentSnapshot(
                taskID: fixture.task.id,
                sourceEventID: nil,
                acceptedTurn: "Read ASTRA-123 in Jira"
            ),
            runtime: .cursorCLI
        )
        let runID = UUID()
        let unavailable = "/tmp/astra-missing-helper-\(UUID().uuidString)"

        #expect(!HostControlBrokerSessionRegistry.shared.prepare(
            task: fixture.task,
            runID: runID,
            capabilityScope: snapshot.providerLaunch,
            requiredTools: ["jira"],
            currentDirectory: "/tmp",
            expectedHelperPath: unavailable
        ))
        #expect(
            HostControlBrokerSessionRegistry.shared.endpoint(
                taskID: fixture.task.id,
                runID: runID
            ) == nil
        )
    }

    @Test("Registered bundled helper relays host-control JSON-RPC")
    func registeredBundledHelperRelaysJSONRPC() throws {
        let fixture = try makeJiraAdmissionFixture()
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: "Read ASTRA-123 in Jira",
            turnIntentSnapshot: TaskTurnIntentSnapshot(
                taskID: fixture.task.id,
                sourceEventID: nil,
                acceptedTurn: "Read ASTRA-123 in Jira"
            ),
            runtime: .claudeCode
        )
        let runID = UUID()
        let helperPath = try builtHostControlHelperPath()
        let prepared = HostControlBrokerSessionRegistry.shared.prepare(
            task: fixture.task,
            runID: runID,
            capabilityScope: snapshot.providerLaunch,
            requiredTools: ["jira"],
            currentDirectory: "/tmp",
            expectedHelperPath: helperPath
        )
        defer {
            HostControlBrokerSessionRegistry.shared.stop(taskID: fixture.task.id, runID: runID)
        }
        #expect(prepared)
        HostControlBrokerSessionRegistry.shared.registerProviderProcess(
            taskID: fixture.task.id,
            runID: runID,
            processID: getpid()
        )
        let socketPath = try #require(
            HostControlBrokerSessionRegistry.shared.endpoint(taskID: fixture.task.id, runID: runID)
        )

        let result = try runHostControlHelper(
            at: helperPath,
            socketPath: socketPath,
            requestLines: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ASTRA tests","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains(#""id":1"#))
        #expect(result.output.contains(#""name":"astra-host-control""#))
        #expect(result.output.contains(#""name":"jira""#))

        let cliResult = try runHostControlHelper(
            at: helperPath,
            socketPath: socketPath,
            arguments: ["jira", "--operation", "status", "--alias", "jira"],
            requestLines: []
        )
        #expect([0, 1].contains(cliResult.exitCode))
        #expect(cliResult.output.contains(#""id":1"#))
        #expect(!cliResult.output.contains("disconnected"))
    }

    @Test("Broker rejects helper outside the registered provider ancestry")
    func brokerRejectsUnregisteredHelperAncestry() throws {
        let fixture = try makeJiraAdmissionFixture()
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: "Read ASTRA-123 in Jira",
            turnIntentSnapshot: TaskTurnIntentSnapshot(
                taskID: fixture.task.id,
                sourceEventID: nil,
                acceptedTurn: "Read ASTRA-123 in Jira"
            ),
            runtime: .claudeCode
        )
        let runID = UUID()
        let helperPath = try builtHostControlHelperPath()
        let prepared = HostControlBrokerSessionRegistry.shared.prepare(
            task: fixture.task,
            runID: runID,
            capabilityScope: snapshot.providerLaunch,
            requiredTools: ["jira"],
            currentDirectory: "/tmp",
            expectedHelperPath: helperPath
        )
        defer {
            HostControlBrokerSessionRegistry.shared.stop(taskID: fixture.task.id, runID: runID)
        }
        #expect(prepared)
        HostControlBrokerSessionRegistry.shared.registerProviderProcess(
            taskID: fixture.task.id,
            runID: runID,
            processID: Int32.max
        )
        let socketPath = try #require(
            HostControlBrokerSessionRegistry.shared.endpoint(taskID: fixture.task.id, runID: runID)
        )

        let result = try runHostControlHelper(
            at: helperPath,
            socketPath: socketPath,
            requestLines: [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ASTRA tests","version":"1"}}}"#
            ]
        )

        #expect(result.output.contains("disconnected"))
        #expect(!result.output.contains(#""name":"astra-host-control""#))
    }

    private func builtHostControlHelperPath() throws -> String {
        let path = Bundle.module.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("astra-host-control", isDirectory: false)
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return path
    }

    private func runHostControlHelper(
        at helperPath: String,
        socketPath: String,
        arguments: [String] = [],
        requestLines: [String]
    ) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        var environment = ProcessInfo.processInfo.environment
        environment[HostControlBrokerIPC.endpointEnvironmentKey] = socketPath
        process.environment = environment

        try process.run()
        if !requestLines.isEmpty {
            let request = requestLines.joined(separator: "\n") + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: response, as: UTF8.self)
        )
    }

    @Test("Composer preview signature tracks the live attachment list")
    func previewSignatureTracksAttachments() throws {
        let container = try makeContainer()
        let workspace = Workspace(name: "Attachments", primaryPath: "/tmp")
        container.mainContext.insert(workspace)
        try container.mainContext.save()

        func request(attachedFiles: [String]) -> RuntimeEligibilityPreviewRequest {
            .newTask(
                draftTask: nil,
                workspace: workspace,
                selectedSkills: [],
                attachedFiles: attachedFiles,
                acceptedTurn: "Summarize the attached file",
                requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: true,
                selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                skipPermissions: false,
                defaultModel: TaskExecutionDefaults.model,
                defaultBudget: TaskExecutionDefaults.tokenBudget,
                providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready]
            )
        }

        // Attaching a file changes the task that will be submitted, so it must also
        // re-trigger the debounced preview instead of reusing the previous verdict.
        #expect(request(attachedFiles: []).signature != request(attachedFiles: ["/tmp/a.txt"]).signature)
        #expect(request(attachedFiles: ["/tmp/a.txt"]).signature
            != request(attachedFiles: ["/tmp/b.txt"]).signature)
    }

    @Test("Composer preview rejects a missing attachment before the task is enqueued")
    func previewRejectsMissingComposerAttachment() async throws {
        let container = try makeContainer()
        let workspace = Workspace(name: "Attachments", primaryPath: "/tmp")
        container.mainContext.insert(workspace)
        try container.mainContext.save()
        let missing = "/tmp/astra-missing-attachment-\(UUID().uuidString).txt"

        func candidate(attachedFiles: [String]) async throws -> TaskRuntimeAdmissionCandidate {
            let request = RuntimeEligibilityPreviewRequest.newTask(
                draftTask: nil,
                workspace: workspace,
                selectedSkills: [],
                attachedFiles: attachedFiles,
                acceptedTurn: "Summarize the attached file",
                requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: true,
                selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                skipPermissions: false,
                defaultModel: TaskExecutionDefaults.model,
                defaultBudget: TaskExecutionDefaults.tokenBudget,
                providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready]
            )
            let snapshot = try #require(await request.evaluate())
            return try #require(snapshot.candidates[.claudeCode])
        }

        let withAttachment = try await candidate(attachedFiles: [missing])
        #expect(withAttachment.launchResourcePlan.diagnostics.contains { $0.code == "input_path_missing" })
        #expect(!withAttachment.isEligible)

        let withoutAttachment = try await candidate(attachedFiles: [])
        #expect(!withoutAttachment.launchResourcePlan.diagnostics.contains { $0.code == "input_path_missing" })
    }

    @Test("Composer preview projects the live skill selection over a persisted draft")
    func previewProjectsLiveSkillSelectionOverDraft() async throws {
        let fixture = try makeJiraAdmissionFixture()
        let draft = fixture.task
        let skill = try #require(draft.skills.first)

        func behaviorSkillNames(selectedSkills: [Skill]) async throws -> [String] {
            let request = RuntimeEligibilityPreviewRequest.newTask(
                draftTask: draft,
                workspace: draft.workspace,
                selectedSkills: selectedSkills,
                attachedFiles: [],
                acceptedTurn: "Read ASTRA-123 in Jira",
                requestedRuntime: .claudeCode,
                runtimeExplicitlySelected: true,
                selectedPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                skipPermissions: false,
                defaultModel: TaskExecutionDefaults.model,
                defaultBudget: TaskExecutionDefaults.tokenBudget,
                providerSettings: .headlessScenario,
                readinessStates: [.claudeCode: .ready]
            )
            let snapshot = try #require(await request.evaluate())
            let candidate = try #require(snapshot.candidates[.claudeCode])
            return candidate.capabilityResolutionSnapshot.providerLaunch.behaviorSkills.map(\.name)
        }

        // The composer toggles skills without writing the draft, so the preview must
        // follow the live selection rather than the draft's last saved set.
        #expect(try await behaviorSkillNames(selectedSkills: []).isEmpty)
        #expect(try await behaviorSkillNames(selectedSkills: [skill]).contains(skill.name))

        // Previewing must stay read-only: the draft is durable state the composer owns.
        #expect(draft.skills.map(\.name) == [skill.name])
        #expect(draft.inputs.isEmpty)
        #expect(draft.events.allSatisfy { $0.type != TaskPolicyStore.selectedPolicyEventType })
    }

    @Test("A long turn keeps the capability signal in its closing sentence")
    func boundedTurnPreservesTrailingActivationSignal() throws {
        let fixture = try makeJiraAdmissionFixture()
        let filler = String(repeating: "Summarize the release notes for the platform team. ", count: 400)
        let turn = filler + "When the summary is ready, file it as a ticket in Jira."
        #expect(turn.count > 8_000)

        let intent = TaskTurnIntentResolver.preview(for: fixture.task, acceptedTurn: turn)

        // Head-only truncation would drop the trailing "Jira" and silently deactivate the
        // capability the turn actually asks for.
        #expect(intent.acceptedTurn.count <= 8_000)
        #expect(intent.acceptedTurn.hasSuffix("file it as a ticket in Jira."))
        #expect(intent.acceptedTurn.hasPrefix("Summarize the release notes"))
        #expect(intent.acceptedTurn.contains("\u{2026}"))

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: intent.activationText,
            turnIntentSnapshot: intent,
            runtime: .claudeCode
        )
        #expect(snapshot.providerLaunch.connectors.map(\.id) == [fixture.connector.id])
    }

    private func makeJiraAdmissionFixture() throws -> (
        container: ModelContainer,
        task: AgentTask,
        connector: Connector
    ) {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira admission", primaryPath: "/tmp")
        let skill = Skill(
            name: "Jira Agent",
            skillDescription: "Read Jira tickets",
            behaviorInstructions: "Always use ASTRA host-control MCP tool mcp__astra_host__jira; do not use Bash."
        )
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira issues",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["ASTRA"]
        connector.skill = skill
        connector.workspace = workspace
        let task = AgentTask(
            title: "Jira",
            goal: "Read ASTRA-123 in Jira",
            workspace: workspace,
            runtime: .claudeCode
        )
        task.skills = [skill]
        context.insert(workspace)
        context.insert(skill)
        context.insert(connector)
        context.insert(task)
        try context.save()
        return (container, task, connector)
    }

    private func runtimeConfiguration(
        runtimes: [AgentRuntimeID],
        defaultRuntime: AgentRuntimeID
    ) -> AgentRuntimeConfiguration {
        let paths = Dictionary(uniqueKeysWithValues: runtimes.map { ($0, "/usr/bin/true") })
        return AgentRuntimeConfiguration(
            providerSettings: AgentRuntimeProviderSettings(executablePaths: paths),
            defaultRuntimeID: defaultRuntime
        )
    }
}

private struct StaticAdmissionSecretStore: SecretStore {
    let values: [String: String]

    func load(key: String, entityID _: String) -> String? {
        values[key]
    }

    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool {
        false
    }

    func delete(key _: String, entityID _: String) -> Bool {
        false
    }

    func deleteAll(entityID _: String) {}

    func exists(key: String, entityID _: String) -> Bool {
        values[key] != nil
    }
}
