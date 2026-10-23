import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Workspace right rail performance")
struct WorkspaceRightRailPerformanceTests {
    @MainActor
    @Test("GitHub read-only mode preserves GitHub-origin behavior skill semantics")
    func githubReadOnlyModeUsesBehaviorSkillOrigin() {
        let workspace = makeWorkspace(name: "Origin semantics")
        workspace.enabledCapabilityIDs = []
        let task = AgentTask(title: "Inspect", goal: "Inspect the proposed change")
        task.workspace = workspace
        let skill = Skill(name: "Change reviewer", allowedTools: ["Read"])
        skill.behaviorInstructions = "Inspect the proposed change and report risks."
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        task.skills = [skill]

        let scope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: "Inspect the proposed change"
        ).providerLaunch
        let snapshot = HostControlPlaneMCPProjection.CapabilitySnapshot(capabilityScope: scope)

        #expect(!scope.enabledPackageIDs.contains(HostControlPlaneMCPProjection.githubPackageID))
        #expect(!skill.behaviorInstructions.localizedCaseInsensitiveContains("github"))
        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded host-control input preserves GitHub-origin behavior skill semantics")
    func boundedHostControlInputPreservesBehaviorSkillOrigin() {
        let workspace = makeWorkspace(name: "Bounded origin semantics")
        let task = AgentTask(title: "Inspect", goal: "Inspect the proposed change")
        task.workspace = workspace
        let skill = Skill(name: "Change reviewer", allowedTools: ["Read"])
        skill.behaviorInstructions = "Inspect the proposed change and report risks."
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        task.skills = [skill]

        let input = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: "Inspect the proposed change")
        let snapshot = input.resolve(packageDefinitions: [])

        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded host-control input stays read-only for detached historical snapshot")
    func boundedHostControlInputFailsClosedForDetachedHistoricalSnapshot() {
        let workspace = makeWorkspace(name: "Historical semantics")
        let task = AgentTask(title: "Review GitHub", goal: "Review the GitHub pull request")
        task.workspace = workspace
        let historicalSkill = Skill(name: "Historical GitHub reviewer", allowedTools: ["Read"])
        historicalSkill.behaviorInstructions =
            "Host-control is required; always use astra_host.github and do not use native shell."
        task.skillSnapshots = [SkillSnapshotConfig(skill: historicalSkill)]

        let contextText = "Review the GitHub pull request"
        let bounded = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: contextText
        ).resolve(packageDefinitions: [])

        #expect(!bounded.resolutionIsComplete)
        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: bounded))
    }

    @MainActor
    @Test("Bounded host-control input includes connector-owned GitHub behavior")
    func boundedHostControlInputIncludesConnectorBehavior() {
        let workspace = makeWorkspace(name: "Connector semantics")
        let task = AgentTask(title: "Review GitHub", goal: "Review the GitHub change")
        task.workspace = workspace
        let skill = Skill(name: "GitHub connector", allowedTools: ["Read"])
        skill.behaviorInstructions = "Host-control is required; always use astra_host.github and do not use native shell."
        let connector = Connector(name: "GitHub", serviceType: "github")
        connector.skill = skill
        connector.workspace = workspace
        workspace.connectors = [connector]

        let input = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: "Review GitHub")
        let snapshot = input.resolve(packageDefinitions: [])

        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded host-control input fails closed for package-backed resolution")
    func boundedHostControlInputFailsClosedForPackageBackedResolution() {
        let workspace = makeWorkspace(name: "Pruning semantics")
        workspace.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let task = AgentTask(title: "Summarize notes", goal: "Summarize local meeting notes")
        task.workspace = workspace
        var githubPackage = browserAdapterPackage(
            id: HostControlPlaneMCPProjection.githubPackageID,
            adapterID: BrowserSiteAdapterID.github
        )
        githubPackage.skills = [PluginSkill(
            name: "GitHub workflow",
            icon: "arrow.triangle.branch",
            description: "Operate GitHub workflows",
            allowedTools: ["Read"],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "Use GitHub workflow tools.",
            environmentKeys: [],
            environmentValues: []
        )]

        let input = BrowserSessionPolicyContext.HostControlInput(
            task: task,
            enabledPackageIDs: workspace.enabledCapabilityIDs,
            contextText: "Summarize local meeting notes"
        )
        let snapshot = input.resolve(packageDefinitions: [githubPackage])

        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded host-control input fails closed for active-objective reconstruction")
    func boundedHostControlInputFailsClosedForActiveObjectiveReconstruction() {
        let workspace = makeWorkspace(name: "Objective semantics")
        let task = AgentTask(title: "Local notes", goal: "Summarize local notes", workspace: workspace)
        task.events = [TaskEvent(task: task, type: TaskEventTypes.Plan.updated.rawValue,
            payload: #"{"goal":"Review the GitHub pull request"}"#)]

        let snapshot = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: "Summarize local notes"
        ).resolve(packageDefinitions: [])

        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded host-control input fails closed for enabled global resources")
    func boundedHostControlInputFailsClosedForEnabledGlobalResources() {
        let workspace = makeWorkspace(name: "Global semantics")
        workspace.enabledGlobalConnectorIDs = [UUID().uuidString]
        let task = AgentTask(title: "Local notes", goal: "Summarize local notes", workspace: workspace)

        let snapshot = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: "Summarize local notes"
        ).resolve(packageDefinitions: [])

        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Bounded input without maintained proof remains read-only")
    func boundedInputWithoutProofRemainsReadOnly() {
        let workspace = makeWorkspace(name: "Strict semantics")
        let task = AgentTask(title: "Local notes", goal: "Summarize local notes", workspace: workspace)

        let snapshot = BrowserSessionPolicyContext.HostControlInput(
            task: task, enabledPackageIDs: [], contextText: "Summarize local notes"
        ).resolve(packageDefinitions: [])

        #expect(!snapshot.resolutionIsComplete)
        #expect(HostControlPlaneMCPProjection.githubIsEnabled(for: .host, capabilitySnapshot: snapshot))
    }

    @MainActor
    @Test("Host-control admission stays bounded with a large loaded history")
    func hostControlAdmissionStaysBoundedWithLargeHistory() {
        let task = AgentTask(title: "Local notes", goal: "Summarize local notes")
        task.events = (0..<20_000).map { index in
            TaskEvent(task: task, type: "user.message", payload: "historical message \(index)")
        }
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            _ = BrowserSessionPolicyContext.HostControlInput(
                task: task, enabledPackageIDs: [], contextText: "Summarize local notes"
            )
        }

        #expect(elapsed < .milliseconds(50))
    }

    @Test("Latest browser policy context preserves GitHub read-only classification")
    func latestBrowserPolicyContextUsesLatestUserProjection() {
        let text = BrowserSessionPolicyContext.latestContextText(in: .init(
            goal: "fallback goal",
            latestUserMessage: "please review this GitHub pull request"
        ))
        #expect(text == "please review this GitHub pull request")
        #expect(text.localizedCaseInsensitiveContains("github"))
    }

    @Test("Browser policy context projection handles large histories and preserves goal fallback")
    func browserPolicyContextProjectionHandlesLargeHistories() {
        let snapshot = BrowserSessionPolicyContext.Snapshot(goal: "GitHub fallback goal", latestUserMessage: nil)

        #expect(BrowserSessionPolicyContext.latestContextText(in: snapshot) == "GitHub fallback goal")
    }

    @Test("Durable user event insertion publishes a task-scoped revision without mutating the task")
    @MainActor
    func durableUserEventInsertionPublishesTaskScopedRevision() throws {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Review local files")
        context.insert(task)
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Review GitHub")
        let originalUpdatedAt = task.updatedAt
        var received: DurableTaskEventInsertion?
        let observer = NotificationCenter.default.addObserver(
            forName: .durableTaskEventInserted, object: nil, queue: nil
        ) { notification in
            received = notification.object as? DurableTaskEventInsertion
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        TaskEventInsertionService.insert(event, into: context)

        #expect(received?.taskID == task.id)
        #expect(received?.eventID == event.id)
        #expect(received?.payload == "Review GitHub")
        #expect(task.updatedAt == originalUpdatedAt)
    }

    @Test("Browser policy run existence query is bounded to one row")
    @MainActor
    func browserPolicyRunExistenceQueryIsBounded() throws {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Draft", goal: "Draft")
        context.insert(task)
        #expect(!BrowserSessionPolicyContext.hasRuns(taskID: task.id, modelContext: context))
        context.insert(TaskRun(task: task))
        try context.save()
        #expect(BrowserSessionPolicyContext.hasRuns(taskID: task.id, modelContext: context))
    }

    @Test("Browser policy task projection keeps the newest durable user event")
    @MainActor
    func browserPolicyTaskProjectionRejectsLaterInsertionOfOlderEvent() throws {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Review", goal: "Review local files")
        context.insert(task)

        let initial = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "newest durable context"
        )
        initial.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(initial)

        var projection = BrowserSessionPolicyTaskProjection()
        #expect(projection.latestUserMessage(for: task.id, modelContext: context) == "newest durable context")

        let olderInsertion = DurableTaskEventInsertion(
            taskID: task.id,
            eventID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            type: TaskEventTypes.Conversation.userMessage.rawValue,
            payload: "older context inserted afterward",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let invalidated = projection.record(olderInsertion, selectedTaskID: task.id)
        #expect(invalidated)
        #expect(projection.latestUserMessage(for: task.id, modelContext: context) == "newest durable context")
        #expect(projection.revision(for: task) == olderInsertion.eventID.uuidString)
    }

    @Test("Browser policy refresh gate fails closed and rejects stale results")
    func browserPolicyRefreshGateRejectsStaleResults() {
        var gate = BrowserSessionPolicyRefreshGate()
        let first = gate.begin()
        let second = gate.begin()
        let permissive = BrowserSessionPolicy(
            enabledBrowserAdapters: [BrowserSiteAdapterID.github],
            githubReadOnlyMode: false
        )

        #expect(gate.policy == .failClosed)
        let acceptedFirst = gate.accept(permissive, for: first)
        #expect(!acceptedFirst)
        #expect(gate.policy == .failClosed)
        let acceptedSecond = gate.accept(permissive, for: second)
        #expect(acceptedSecond)
        #expect(gate.policy == permissive)
    }

    @Test("Browser policy invalidations fail closed for approvals, packages, events, and workspace switches")
    func browserPolicyInvalidationsFailClosed() {
        var gate = BrowserSessionPolicyRefreshGate()
        let permissive = BrowserSessionPolicy(
            enabledBrowserAdapters: [BrowserSiteAdapterID.github],
            githubReadOnlyMode: false
        )

        for _ in ["approvals", "packages", "task-events", "workspace-switch"] {
            let token = gate.begin()
            #expect(gate.policy == .failClosed)
            let accepted = gate.accept(permissive, for: token)
            #expect(accepted)
            #expect(gate.policy == permissive)
        }
    }

    @Test("Browser policy trigger invalidates for task events capabilities and workspace switches")
    func browserPolicyTriggerInvalidatesForObservableInputs() {
        let taskID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let stable = BrowserSessionPolicyRefreshTrigger(
            taskID: taskID,
            workspaceID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            enabledCapabilityIDs: ["github"],
            taskCanvasRevision: "canvas:1",
            taskRevision: "task:2",
            workspaceRevision: "workspace:1",
            environmentRevision: "environment:1"
        )

        #expect(BrowserSessionPolicyRefreshTrigger(
            taskID: taskID,
            workspaceID: stable.workspaceID,
            enabledCapabilityIDs: ["github"],
            taskCanvasRevision: "canvas:1",
            taskRevision: "task:3",
            workspaceRevision: "workspace:1",
            environmentRevision: "environment:1"
        ).rawValue != stable.rawValue)
        #expect(BrowserSessionPolicyRefreshTrigger(
            taskID: taskID,
            workspaceID: stable.workspaceID,
            enabledCapabilityIDs: ["github", "jira"],
            taskCanvasRevision: "canvas:1",
            taskRevision: "task:2",
            workspaceRevision: "workspace:1",
            environmentRevision: "environment:1"
        ).rawValue != stable.rawValue)
        #expect(BrowserSessionPolicyRefreshTrigger(
            taskID: taskID,
            workspaceID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            enabledCapabilityIDs: ["github"],
            taskCanvasRevision: "canvas:1",
            taskRevision: "task:2",
            workspaceRevision: "workspace:2",
            environmentRevision: "environment:1"
        ).rawValue != stable.rawValue)
        #expect(BrowserSessionPolicyRefreshTrigger(
            taskID: taskID,
            workspaceID: stable.workspaceID,
            enabledCapabilityIDs: ["github"],
            taskCanvasRevision: "canvas:1",
            taskRevision: "task:2",
            workspaceRevision: "workspace:1",
            environmentRevision: "environment:2"
        ).rawValue != stable.rawValue)
    }

    @Test("Browser session policy cache reuses stable signatures without reloading policy inputs")
    func browserSessionPolicyCacheReusesStableSignature() {
        let taskID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        var packageLoadCount = 0
        var approvalLoadCount = 0
        var eventContextLoadCount = 0

        let package = browserAdapterPackage(id: "github-workflow", adapterID: BrowserSiteAdapterID.github)
        var source = BrowserSessionPolicySource(
            packageDefinitions: {
                packageLoadCount += 1
                return [package]
            },
            approvalRecords: {
                approvalLoadCount += 1
                return []
            },
            latestContextText: {
                eventContextLoadCount += 1
                return "please review this GitHub pull request"
            },
            environment: { .host }
        )
        var cache = BrowserSessionPolicyCache()
        let stable = BrowserSessionPolicySignature(
            taskID: taskID,
            workspaceID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            environmentRevision: "host:1",
            enabledCapabilityIDs: ["github-workflow"],
            approvalRevision: "approval:1",
            packageDefinitionFingerprint: "packages:v1",
            taskEventRevision: "events:v1"
        )

        let first = cache.policy(for: stable, source: source)
        let second = cache.policy(for: stable, source: source)

        #expect(first.enabledBrowserAdapters == [BrowserSiteAdapterID.github])
        #expect(second.enabledBrowserAdapters == [BrowserSiteAdapterID.github])
        #expect(packageLoadCount == 1)
        #expect(approvalLoadCount == 1)
        #expect(eventContextLoadCount == 1)

        _ = cache.policy(
            for: BrowserSessionPolicySignature(
                taskID: taskID,
                workspaceID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                environmentRevision: "docker:2",
                enabledCapabilityIDs: ["github-workflow"],
                approvalRevision: "approval:1",
                packageDefinitionFingerprint: "packages:v1",
                taskEventRevision: "events:v1"
            ),
            source: source
        )
        #expect(packageLoadCount == 2)

        source = BrowserSessionPolicySource(
            packageDefinitions: {
                packageLoadCount += 1
                return [package]
            },
            approvalRecords: {
                approvalLoadCount += 1
                return []
            },
            latestContextText: {
                eventContextLoadCount += 1
                return "please review this GitHub pull request"
            },
            environment: { .host }
        )
        _ = cache.policy(
            for: BrowserSessionPolicySignature(
                taskID: taskID,
                enabledCapabilityIDs: ["github-workflow"],
                approvalRevision: "approval:2",
                packageDefinitionFingerprint: "packages:v1",
                taskEventRevision: "events:v1"
            ),
            source: source
        )

        #expect(packageLoadCount == 3)
        #expect(approvalLoadCount == 3)
        #expect(eventContextLoadCount == 3)

        _ = cache.policy(
            for: BrowserSessionPolicySignature(
                taskID: taskID,
                enabledCapabilityIDs: ["github-workflow"],
                approvalRevision: "approval:2",
                packageDefinitionFingerprint: "packages:v2",
                taskEventRevision: "events:v1"
            ),
            source: source
        )

        #expect(packageLoadCount == 4)
        #expect(approvalLoadCount == 4)
        #expect(eventContextLoadCount == 4)

        _ = cache.policy(
            for: BrowserSessionPolicySignature(
                taskID: taskID,
                enabledCapabilityIDs: ["github-workflow"],
                approvalRevision: "approval:2",
                packageDefinitionFingerprint: "packages:v2",
                taskEventRevision: "events:v1",
                catalogPolicyRevision: "packs:v2"
            ),
            source: source
        )
        #expect(packageLoadCount == 5)
    }

    @Test("Browser session policy cache fails closed when refresh throws")
    func browserSessionPolicyCacheFailsClosedOnRefreshFailure() {
        var cache = BrowserSessionPolicyCache()
        let policy = cache.policy(
            for: BrowserSessionPolicySignature(
                taskID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                enabledCapabilityIDs: ["github-workflow"],
                approvalRevision: "approval:1",
                packageDefinitionFingerprint: "packages:v1",
                taskEventRevision: "events:v1"
            ),
            source: BrowserSessionPolicySource(
                packageDefinitions: { throw BrowserSessionPolicyCacheTestError.unavailable },
                approvalRecords: { [] },
                latestContextText: { "github" },
                environment: { .host }
            )
        )

        #expect(policy == .failClosed)
        #expect(policy.githubReadOnlyMode == true)
        #expect(BrowserSiteActionPolicy.denialReason(
            batchAction: "fill",
            currentURL: "https://github.com/aandresalvarez/astra/pull/177",
            enabledBrowserAdapters: Set(policy.enabledBrowserAdapters),
            githubReadOnlyMode: policy.githubReadOnlyMode
        ) == BrowserSiteActionPolicy.gitHubReadOnlyDenialReason)
    }

    @MainActor
    @Test("Capability rail snapshot cache reuses stable signature and invalidates on capability changes")
    func capabilityRailSnapshotCacheReusesStableSignature() {
        let workspace = makeWorkspace(name: "Capabilities")
        let globalSkill = Skill(name: "Jira Agent", allowedTools: ["Read"])
        globalSkill.isGlobal = true
        workspace.enabledGlobalSkillIDs = [globalSkill.id.uuidString]

        let package = PluginPackage(
            id: "jira-workflow",
            name: "Jira",
            icon: "ticket",
            description: "Jira workflow support",
            author: "ASTRA",
            category: "Workflow",
            tags: ["jira"],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "Jira Agent",
                    icon: "ticket",
                    description: "Use Jira",
                    allowedTools: ["Read"],
                    disallowedTools: [],
                    customTools: [],
                    behaviorInstructions: "",
                    environmentKeys: [],
                    environmentValues: []
                )
            ],
            connectors: [],
            localTools: [],
            templates: []
        )

        let signature = CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: [globalSkill],
            globalConnectors: [],
            globalTools: [],
            packages: [package],
            approvalRecords: [],
            prerequisiteStatuses: [:]
        )

        var cache = CapabilityRailSnapshotCache()
        #expect(cache.snapshot(for: signature) == nil)

        cache.store(.empty, for: signature)

        #expect(cache.matches(signature))
        #expect(cache.snapshot(for: signature) != nil)

        workspace.updatedAt = Date(timeIntervalSince1970: 10)
        let timestampOnlySignature = CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: [globalSkill],
            globalConnectors: [],
            globalTools: [],
            packages: [package],
            approvalRecords: [],
            prerequisiteStatuses: [:]
        )

        #expect(cache.matches(timestampOnlySignature))
        #expect(cache.snapshot(for: timestampOnlySignature) != nil)

        workspace.enabledCapabilityIDs = ["jira-workflow"]
        let changedSignature = CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: [globalSkill],
            globalConnectors: [],
            globalTools: [],
            packages: [package],
            approvalRecords: [],
            prerequisiteStatuses: [:]
        )

        #expect(!cache.matches(changedSignature))
        #expect(cache.snapshot(for: changedSignature) == nil)

        cache.store(.empty, for: changedSignature)

        #expect(cache.snapshot(for: signature) != nil)
        #expect(cache.snapshot(for: changedSignature) != nil)

        var oneEntryCache = CapabilityRailSnapshotCache(capacity: 1)
        oneEntryCache.store(.empty, for: signature)
        oneEntryCache.store(.empty, for: changedSignature)

        #expect(oneEntryCache.snapshot(for: signature) == nil)
        #expect(oneEntryCache.snapshot(for: changedSignature) != nil)
    }

    @MainActor
    @Test("Capability rail signature invalidates when pack policy changes")
    func capabilityRailSignatureInvalidatesOnPackPolicyChanges() {
        let workspace = makeWorkspace(name: "Pack Policy")
        let visiblePolicy = PackResolvedPolicy.empty
        let unresolvedPolicy = PackResolvedPolicy.unresolvedEnabledPacks(["astra.pack.missing"])

        let visibleSignature = CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: [],
            globalConnectors: [],
            globalTools: [],
            packages: [],
            approvalRecords: [],
            packPolicy: visiblePolicy,
            prerequisiteStatuses: [:]
        )
        let unresolvedSignature = CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: [],
            globalConnectors: [],
            globalTools: [],
            packages: [],
            approvalRecords: [],
            packPolicy: unresolvedPolicy,
            prerequisiteStatuses: [:]
        )

        #expect(visibleSignature != unresolvedSignature)
    }

    @Test("Approved capability refresh asks rail to rebuild and refresh prerequisites")
    func approvedCapabilityRefreshRequestsDependentRefreshes() {
        let unchanged = WorkspaceRightRailApprovedCapabilityRefreshPlan.make(
            previousPackageIDs: ["builtin.github"],
            nextPackageIDs: ["builtin.github"],
            previousPolicy: .empty,
            nextPolicy: .empty
        )
        let changed = WorkspaceRightRailApprovedCapabilityRefreshPlan.make(
            previousPackageIDs: ["builtin.github"],
            nextPackageIDs: ["builtin.github", "jira-workflow"],
            previousPolicy: .empty,
            nextPolicy: .unresolvedEnabledPacks(["astra.pack.missing"])
        )

        #expect(!unchanged.shouldRebuildSnapshot)
        #expect(!unchanged.shouldRefreshPrerequisites)
        #expect(changed.shouldRebuildSnapshot)
        #expect(changed.shouldRefreshPrerequisites)
    }

    @MainActor
    @Test("Capability rail signature preserves installed plugin ID version pairings")
    func capabilityRailSignaturePreservesInstalledPluginVersionPairings() {
        let firstWorkspace = makeWorkspace(name: "Installed Plugins")
        firstWorkspace.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        firstWorkspace.installedPluginIDs = ["plugin-b", "plugin-a"]
        firstWorkspace.installedPluginVersions = ["2.0.0", "1.0.0"]

        let secondWorkspace = makeWorkspace(name: "Installed Plugins")
        secondWorkspace.id = firstWorkspace.id
        secondWorkspace.installedPluginIDs = ["plugin-a", "plugin-b"]
        secondWorkspace.installedPluginVersions = ["2.0.0", "1.0.0"]

        let firstSignature = CapabilityRailSnapshotSignature(
            workspace: firstWorkspace,
            globalSkills: [],
            globalConnectors: [],
            globalTools: [],
            packages: [],
            approvalRecords: [],
            prerequisiteStatuses: [:]
        )
        let secondSignature = CapabilityRailSnapshotSignature(
            workspace: secondWorkspace,
            globalSkills: [],
            globalConnectors: [],
            globalTools: [],
            packages: [],
            approvalRecords: [],
            prerequisiteStatuses: [:]
        )

        #expect(firstWorkspace.installedVersion(of: "plugin-a") == "1.0.0")
        #expect(secondWorkspace.installedVersion(of: "plugin-a") == "2.0.0")
        #expect(firstSignature != secondSignature)
    }

    @MainActor
    @Test("Capability rail connector signature preserves fixed field order")
    func capabilityRailConnectorSignaturePreservesFixedFieldOrder() {
        let first = Connector(name: "API", serviceType: "jira", authMethod: "api_key")
        first.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        first.updatedAt = Date(timeIntervalSince1970: 20)

        let second = Connector(name: "API", serviceType: "api_key", authMethod: "jira")
        second.id = first.id
        second.updatedAt = first.updatedAt

        #expect(CapabilityRailResourceSignature(connector: first) != CapabilityRailResourceSignature(connector: second))
    }

    @MainActor
    @Test("Capability rail connector signature sorts unordered key lists without mixing categories")
    func capabilityRailConnectorSignatureKeepsKeyCategories() {
        let first = Connector(name: "API", serviceType: "rest_api", authMethod: "bearer")
        first.id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        first.updatedAt = Date(timeIntervalSince1970: 30)
        first.credentialKeys = ["token", "secret"]
        first.configKeys = ["base_url", "project"]

        let sameDifferentOrder = Connector(name: "API", serviceType: "rest_api", authMethod: "bearer")
        sameDifferentOrder.id = first.id
        sameDifferentOrder.updatedAt = first.updatedAt
        sameDifferentOrder.credentialKeys = ["secret", "token"]
        sameDifferentOrder.configKeys = ["project", "base_url"]

        let swappedCategory = Connector(name: "API", serviceType: "rest_api", authMethod: "bearer")
        swappedCategory.id = first.id
        swappedCategory.updatedAt = first.updatedAt
        swappedCategory.credentialKeys = ["base_url", "project"]
        swappedCategory.configKeys = ["secret", "token"]

        #expect(CapabilityRailResourceSignature(connector: first) == CapabilityRailResourceSignature(connector: sameDifferentOrder))
        #expect(CapabilityRailResourceSignature(connector: first) != CapabilityRailResourceSignature(connector: swappedCategory))
    }

    @MainActor
    @Test("Capability rail tool signature preserves fixed field order")
    func capabilityRailToolSignaturePreservesFixedFieldOrder() {
        let first = LocalTool(name: "Runner", toolType: "cli", command: "run", arguments: "--json")
        first.id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        first.updatedAt = Date(timeIntervalSince1970: 40)

        let second = LocalTool(name: "Runner", toolType: "run", command: "cli", arguments: "--json")
        second.id = first.id
        second.updatedAt = first.updatedAt

        #expect(CapabilityRailResourceSignature(tool: first) != CapabilityRailResourceSignature(tool: second))
    }

    @MainActor
    @Test("Capability rail skill signature keeps tool allowlist categories distinct")
    func capabilityRailSkillSignatureKeepsToolCategoriesDistinct() {
        let first = Skill(name: "Operator", allowedTools: ["Read"], disallowedTools: ["Write"])
        first.id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        first.updatedAt = Date(timeIntervalSince1970: 50)

        let second = Skill(name: "Operator", allowedTools: ["Write"], disallowedTools: ["Read"])
        second.id = first.id
        second.updatedAt = first.updatedAt

        #expect(CapabilityRailResourceSignature(skill: first) != CapabilityRailResourceSignature(skill: second))
    }

    private func browserAdapterPackage(id: String, adapterID: String) -> PluginPackage {
        PluginPackage(
            id: id,
            name: id,
            icon: "globe",
            description: "Browser adapter package",
            author: "ASTRA",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [adapterID]
        )
    }
}

private enum BrowserSessionPolicyCacheTestError: Error {
    case unavailable
}
