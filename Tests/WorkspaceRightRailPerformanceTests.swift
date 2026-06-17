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
}
