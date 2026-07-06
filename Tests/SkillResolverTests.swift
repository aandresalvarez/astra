import Testing
import Foundation
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("SkillResolver — pure unit tests (no SwiftData)")
struct SkillResolverTests {

    private func makeSnapshot(
        name: String = "TestSkill",
        allowedTools: [String] = [],
        disallowedTools: [String] = [],
        customTools: [String] = [],
        behaviorInstructions: String = "",
        localToolSnapshots: [LocalToolSnapshotConfig]? = nil
    ) -> SkillSnapshotConfig {
        SkillSnapshotConfig(
            id: UUID().uuidString,
            name: name,
            icon: "star",
            description: "",
            allowedTools: allowedTools,
            disallowedTools: disallowedTools,
            customTools: customTools,
            behaviorInstructions: behaviorInstructions,
            environmentKeys: [],
            environmentValues: [],
            isGlobal: false,
            connectorIDs: nil,
            localToolIDs: nil,
            connectorSnapshots: nil,
            localToolSnapshots: localToolSnapshots,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func makeResolver(
        snapshots: [SkillSnapshotConfig] = [],
        detached: [SkillSnapshotConfig] = [],
        standaloneTools: [LocalToolSnapshotConfig] = [],
        liveLocalCommands: Set<String> = [],
        liveEnvVars: [String: String] = [:],
        connectorEnvVars: [String: String] = [:]
    ) -> SkillResolver {
        SkillResolver(
            effectiveSnapshots: snapshots,
            detachedSnapshots: detached,
            standaloneToolSnapshots: standaloneTools,
            liveLocalToolCommands: liveLocalCommands,
            liveSkillEnvVars: liveEnvVars,
            connectorEnvVars: connectorEnvVars
        )
    }

    @Test("Empty resolver returns default tools")
    func emptyDefaults() {
        let resolver = makeResolver()
        #expect(Set(resolver.resolvedAllowedTools) == Set(Skill.defaultAllowed))
        #expect(resolver.resolvedDisallowedTools.isEmpty)
        #expect(resolver.resolvedBehaviorInstructions.isEmpty)
        #expect(resolver.toolPermissionConflicts.isEmpty)
    }

    @Test("Single skill restricts tools")
    func singleSkill() {
        let snapshot = makeSnapshot(allowedTools: ["Read", "Grep"])
        let resolver = makeResolver(snapshots: [snapshot])
        #expect(Set(resolver.resolvedAllowedTools) == Set(["Read", "Grep"]))
    }

    @Test("Multiple skills union tools")
    func multipleSkillsUnion() {
        let s1 = makeSnapshot(name: "A", allowedTools: ["Read", "Write"])
        let s2 = makeSnapshot(name: "B", allowedTools: ["Bash", "Grep"])
        let resolver = makeResolver(snapshots: [s1, s2])
        #expect(Set(resolver.resolvedAllowedTools) == Set(["Read", "Write", "Bash", "Grep"]))
    }

    @Test("Disallowed tools override allowed")
    func disallowedOverrides() {
        let s1 = makeSnapshot(name: "A", allowedTools: ["Read", "Write", "Bash"])
        let s2 = makeSnapshot(name: "B", disallowedTools: ["Bash"])
        let resolver = makeResolver(snapshots: [s1, s2])
        #expect(!resolver.resolvedAllowedTools.contains("Bash"))
        #expect(resolver.resolvedAllowedTools.contains("Read"))
    }

    @Test("Disallowed tools override allowed tools case-insensitively")
    func disallowedOverridesCaseInsensitively() {
        let s1 = makeSnapshot(name: "A", allowedTools: ["Read", "Bash"])
        let s2 = makeSnapshot(name: "B", disallowedTools: ["bash"])
        let resolver = makeResolver(snapshots: [s1, s2])

        #expect(resolver.resolvedAllowedTools == ["Read"])
    }

    @Test("Conflict detection across skills")
    func conflictDetection() {
        let s1 = makeSnapshot(name: "Dev", allowedTools: ["Bash", "Write"])
        let s2 = makeSnapshot(name: "Safe", disallowedTools: ["Bash"])
        let resolver = makeResolver(snapshots: [s1, s2])
        let conflicts = resolver.toolPermissionConflicts
        #expect(conflicts.count == 1)
        #expect(conflicts[0].tool == "Bash")
        #expect(conflicts[0].allowedBy == "Dev")
        #expect(conflicts[0].disallowedBy == "Safe")
    }

    @Test("Conflict detection matches tool names case-insensitively")
    func conflictDetectionMatchesToolNamesCaseInsensitively() {
        let dev = makeSnapshot(name: "Dev", allowedTools: ["Bash"])
        let safe = makeSnapshot(name: "Safe", disallowedTools: ["bash"])
        let resolver = makeResolver(snapshots: [dev, safe])

        #expect(resolver.toolPermissionConflicts == [
            SkillResolver.ToolPermissionConflict(tool: "Bash", allowedBy: "Dev", disallowedBy: "Safe")
        ])
    }

    @Test("Duplicate disallowed tools do not crash conflict detection")
    func duplicateDisallowedToolsDoNotCrashConflictDetection() {
        let dev = makeSnapshot(name: "Dev", allowedTools: ["Bash"])
        let safeA = makeSnapshot(name: "Safe A", disallowedTools: ["Bash"])
        let safeB = makeSnapshot(name: "Safe B", disallowedTools: ["Bash"])
        let resolver = makeResolver(snapshots: [dev, safeA, safeB])

        let conflicts = resolver.toolPermissionConflicts

        #expect(conflicts == [
            SkillResolver.ToolPermissionConflict(tool: "Bash", allowedBy: "Dev", disallowedBy: "Safe A"),
            SkillResolver.ToolPermissionConflict(tool: "Bash", allowedBy: "Dev", disallowedBy: "Safe B")
        ])
    }

    @Test("Behavior instructions merge with section headers")
    func behaviorMerge() {
        let s1 = makeSnapshot(name: "Reader", behaviorInstructions: "Only read files")
        let s2 = makeSnapshot(name: "Writer", behaviorInstructions: "Write carefully")
        let resolver = makeResolver(snapshots: [s1, s2])
        let result = resolver.resolvedBehaviorInstructions
        #expect(result.contains("[Reader]:\nOnly read files"))
        #expect(result.contains("[Writer]:\nWrite carefully"))
    }

    @Test("Duplicate behavior snapshots are emitted once")
    func duplicateBehaviorSnapshotsAreEmittedOnce() {
        let behavior = """
        Use GitHub CLI.

        Prefer structured JSON.
        """
        let s1 = makeSnapshot(name: "GitHub Agent", behaviorInstructions: behavior)
        let s2 = makeSnapshot(name: "github agent", behaviorInstructions: "Use GitHub CLI.\nPrefer structured JSON.")
        let resolver = makeResolver(snapshots: [s1, s2])
        let result = resolver.resolvedBehaviorInstructions

        #expect(result.components(separatedBy: "Use GitHub CLI.").count - 1 == 1)
        #expect(result.contains("[GitHub Agent]:"))
    }

    @Test("Empty behavior instructions are skipped")
    func emptyBehaviorSkipped() {
        let s1 = makeSnapshot(name: "A", behaviorInstructions: "Do stuff")
        let s2 = makeSnapshot(name: "B", behaviorInstructions: "")
        let resolver = makeResolver(snapshots: [s1, s2])
        #expect(!resolver.resolvedBehaviorInstructions.contains("[B]"))
    }

    @Test("CLI local tools auto-add Bash")
    func cliToolsAddBash() {
        let cliTool = LocalToolSnapshotConfig(
            id: nil, name: "build", description: "", icon: "",
            toolType: "cli", command: "swift build", arguments: "",
            isGlobal: nil, createdAt: nil, updatedAt: nil
        )
        let snapshot = makeSnapshot(allowedTools: ["Read"], localToolSnapshots: [cliTool])
        let resolver = makeResolver(snapshots: [snapshot])
        #expect(resolver.resolvedAllowedTools.contains("Bash"))
        #expect(resolver.resolvedAllowedTools.contains("swift build"))
    }

    @Test("Claude tools exclude CLI commands")
    func claudeToolsExcludeCLI() {
        let cliTool = LocalToolSnapshotConfig(
            id: nil, name: "build", description: "", icon: "",
            toolType: "cli", command: "swift build", arguments: "",
            isGlobal: nil, createdAt: nil, updatedAt: nil
        )
        let snapshot = makeSnapshot(allowedTools: ["Read", "Write"], localToolSnapshots: [cliTool])
        let resolver = makeResolver(snapshots: [snapshot])
        let claudeTools = resolver.resolvedClaudeAllowedTools
        #expect(!claudeTools.contains("swift build"))
        #expect(claudeTools.contains("Read"))
    }

    @Test("Standalone tools are included")
    func standaloneTools() {
        let standalone = LocalToolSnapshotConfig(
            id: nil, name: "lint", description: "", icon: "",
            toolType: "cli", command: "swiftlint", arguments: "",
            isGlobal: nil, createdAt: nil, updatedAt: nil
        )
        let resolver = makeResolver(standaloneTools: [standalone])
        #expect(resolver.resolvedAllowedTools.contains("swiftlint"))
        #expect(resolver.resolvedAllowedTools.contains("Bash"))
    }

    @Test("Environment variables merge live + detached + connectors")
    func envVarMerge() {
        let detached = SkillSnapshotConfig(
            id: UUID().uuidString, name: "Old",
            icon: "", description: "",
            allowedTools: [], disallowedTools: [], customTools: [],
            behaviorInstructions: "",
            environmentKeys: ["DETACHED_KEY"],
            environmentValues: ["detached_val"],
            isGlobal: false,
            connectorIDs: nil, localToolIDs: nil,
            connectorSnapshots: nil, localToolSnapshots: nil,
            createdAt: nil, updatedAt: nil
        )
        let resolver = makeResolver(
            detached: [detached],
            liveEnvVars: ["LIVE_KEY": "live_val"],
            connectorEnvVars: ["CONN_KEY": "conn_val"]
        )
        let env = resolver.resolvedEnvironmentVariables
        #expect(env["LIVE_KEY"] == "live_val")
        #expect(env["DETACHED_KEY"] == "detached_val")
        #expect(env["CONN_KEY"] == "conn_val")
    }

    @Test("Results are sorted")
    func sortedResults() {
        let s = makeSnapshot(allowedTools: ["Grep", "Bash", "Read", "Write"])
        let resolver = makeResolver(snapshots: [s])
        #expect(resolver.resolvedAllowedTools == resolver.resolvedAllowedTools.sorted())
        #expect(resolver.resolvedDisallowedTools == resolver.resolvedDisallowedTools.sorted())
    }
}
