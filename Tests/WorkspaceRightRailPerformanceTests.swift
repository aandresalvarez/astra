import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Workspace right rail performance")
struct WorkspaceRightRailPerformanceTests {
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
}
