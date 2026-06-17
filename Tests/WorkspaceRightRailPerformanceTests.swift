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
}
