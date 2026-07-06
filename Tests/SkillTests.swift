import Testing
import Foundation
import ASTRAModels
@testable import ASTRA
import ASTRACore

// MARK: - Helper

private func makeTask(
    title: String = "Test Task",
    goal: String = "Do something"
) -> AgentTask {
    AgentTask(title: title, goal: goal)
}

private func makeSkill(
    name: String = "Test Skill",
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    behaviorInstructions: String = ""
) -> Skill {
    Skill(
        name: name,
        allowedTools: allowedTools,
        disallowedTools: disallowedTools,
        behaviorInstructions: behaviorInstructions
    )
}

// MARK: - Skill Model

@Suite("Skill Model")
struct SkillModelTests {

    @Test("Skill initializes with correct defaults")
    func skillDefaults() {
        let skill = Skill()
        #expect(skill.name == "")
        #expect(skill.icon == "puzzlepiece.extension")
        #expect(skill.skillDescription == "")
        #expect(skill.allowedTools.isEmpty)
        #expect(skill.disallowedTools.isEmpty)
        #expect(skill.behaviorInstructions == "")
        #expect(skill.tasks.isEmpty)
    }

    @Test("Skill stores custom values")
    func skillCustomValues() {
        let skill = Skill(
            name: "Read-Only",
            icon: "lock.shield",
            skillDescription: "Read only access",
            allowedTools: ["Read", "Glob", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: "Never modify files"
        )
        #expect(skill.name == "Read-Only")
        #expect(skill.icon == "lock.shield")
        #expect(skill.skillDescription == "Read only access")
        #expect(skill.allowedTools == ["Read", "Glob", "Grep"])
        #expect(skill.disallowedTools == ["Write", "Edit", "Bash"])
        #expect(skill.behaviorInstructions == "Never modify files")
    }

    @Test("knownTools contains all 11 built-in tools")
    func knownTools() {
        #expect(Skill.knownTools.count == 11)
        for tool in ["Read", "Glob", "Grep", "Write", "Edit", "Bash",
                      "WebFetch", "WebSearch", "Agent", "NotebookEdit", "TodoWrite"] {
            #expect(Skill.knownTools.contains(tool))
        }
    }

    @Test("defaultAllowed contains all 6 core tools")
    func defaultAllowed() {
        #expect(Skill.defaultAllowed.count == 6)
        for tool in ["Read", "Glob", "Grep", "Write", "Edit", "Bash"] {
            #expect(Skill.defaultAllowed.contains(tool))
        }
    }

    @Test("toolDescriptions covers all known tools")
    func toolDescriptions() {
        for tool in Skill.knownTools {
            #expect(Skill.toolDescriptions[tool] != nil, "Missing description for \(tool)")
        }
    }

    @Test("customTools defaults to empty")
    func customToolsDefault() {
        let skill = Skill()
        #expect(skill.customTools.isEmpty)
    }
}

// MARK: - Resolved Tools

@Suite("Skill Resolution")
struct SkillResolutionTests {

    @Test("No skills returns default allowed tools")
    func noSkillsDefaultTools() {
        let task = makeTask()
        #expect(task.skills.isEmpty)
        #expect(Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools) == Set(Skill.defaultAllowed))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedDisallowedTools.isEmpty)
    }

    @Test("Single skill restricts allowed tools")
    func singleSkillAllowed() {
        let task = makeTask()
        let skill = makeSkill(allowedTools: ["Read", "Glob", "Grep"])
        task.skills = [skill]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(resolved == Set(["Read", "Glob", "Grep"]))
    }

    @Test("Disallowed tools are removed from allowed")
    func disallowedWins() {
        let task = makeTask()
        let skill = makeSkill(
            allowedTools: ["Read", "Glob", "Grep", "Bash"],
            disallowedTools: ["Bash"]
        )
        task.skills = [skill]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(resolved == Set(["Read", "Glob", "Grep"]))
        #expect(!resolved.contains("Bash"))
    }

    @Test("Disallowed tools from model skills match case-insensitively")
    func disallowedWinsCaseInsensitively() {
        let task = makeTask()
        let skill = makeSkill(
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["bash"]
        )
        task.skills = [skill]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)

        #expect(resolved == Set(["Read"]))
    }

    @Test("Multiple skills union allowed tools")
    func multipleSkillsUnion() {
        let task = makeTask()
        let skill1 = makeSkill(allowedTools: ["Read", "Glob"])
        let skill2 = makeSkill(allowedTools: ["Write", "Edit"])
        task.skills = [skill1, skill2]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(resolved == Set(["Read", "Glob", "Write", "Edit"]))
    }

    @Test("Multiple skills union disallowed tools")
    func multipleSkillsDisallowedUnion() {
        let task = makeTask()
        let skill1 = makeSkill(
            allowedTools: Skill.defaultAllowed,
            disallowedTools: ["Bash"]
        )
        let skill2 = makeSkill(
            allowedTools: Skill.defaultAllowed,
            disallowedTools: ["Write"]
        )
        task.skills = [skill1, skill2]

        let disallowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedDisallowedTools)
        #expect(disallowed.contains("Bash"))
        #expect(disallowed.contains("Write"))

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(!allowed.contains("Bash"))
        #expect(!allowed.contains("Write"))
    }

    @Test("Disallowed from one skill overrides allowed from another")
    func crossSkillConflict() {
        let task = makeTask()
        let skill1 = makeSkill(name: "Writer", allowedTools: ["Read", "Bash"])
        let skill2 = makeSkill(
            name: "Restrictor",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Bash"]
        )
        task.skills = [skill1, skill2]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Grep"))
        #expect(!allowed.contains("Bash"))
    }

    @Test("toolPermissionConflicts detects cross-skill conflicts")
    func conflictDetection() {
        let task = makeTask()
        let skill1 = makeSkill(name: "Writer", allowedTools: ["Read", "Bash"])
        let skill2 = makeSkill(
            name: "Restrictor",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Bash"]
        )
        task.skills = [skill1, skill2]

        let conflicts = TaskCapabilityResolver(task: task).resolver.toolPermissionConflicts
        #expect(conflicts.count == 1)
        #expect(conflicts[0].tool == "Bash")
        #expect(conflicts[0].allowedBy == "Writer")
        #expect(conflicts[0].disallowedBy == "Restrictor")
    }

    @Test("No conflicts when skills don't overlap")
    func noConflicts() {
        let task = makeTask()
        let skill1 = makeSkill(allowedTools: ["Read", "Bash"])
        let skill2 = makeSkill(allowedTools: ["Read", "Grep"])
        task.skills = [skill1, skill2]

        #expect(TaskCapabilityResolver(task: task).resolver.toolPermissionConflicts.isEmpty)
    }

    @Test("Custom tools are included in resolved allowed")
    func customToolsIncluded() {
        let task = makeTask()
        let skill = Skill(
            name: "MCP Skill",
            allowedTools: ["Read", "Bash"],
            customTools: ["mcp__postgres__query", "mcp__slack__send"]
        )
        task.skills = [skill]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(resolved.contains("Read"))
        #expect(resolved.contains("Bash"))
        #expect(resolved.contains("mcp__postgres__query"))
        #expect(resolved.contains("mcp__slack__send"))
    }

    @Test("Custom tools can be disallowed")
    func customToolsDisallowed() {
        let task = makeTask()
        let skill1 = Skill(
            name: "MCP Skill",
            allowedTools: ["Read"],
            customTools: ["mcp__dangerous__tool"]
        )
        let skill2 = makeSkill(
            allowedTools: ["Read"],
            disallowedTools: ["mcp__dangerous__tool"]
        )
        task.skills = [skill1, skill2]

        let resolved = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(resolved.contains("Read"))
        #expect(!resolved.contains("mcp__dangerous__tool"))
    }

    @Test("Resolved tools are sorted")
    func resolvedToolsSorted() {
        let task = makeTask()
        let skill = makeSkill(allowedTools: ["Grep", "Bash", "Read", "Edit"])
        task.skills = [skill]

        let resolved = TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools
        #expect(resolved == resolved.sorted())
    }

    @Test("Resolved disallowed tools are sorted")
    func resolvedDisallowedSorted() {
        let task = makeTask()
        let skill = makeSkill(disallowedTools: ["Write", "Bash", "Edit"])
        task.skills = [skill]

        let resolved = TaskCapabilityResolver(task: task).resolver.resolvedDisallowedTools
        #expect(resolved == resolved.sorted())
    }
}

// MARK: - Behavioral Instructions

@Suite("Behavioral Instructions")
struct BehavioralInstructionsTests {

    @Test("No skills returns empty behavior instructions")
    func noSkillsEmptyBehavior() {
        let task = makeTask()
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.isEmpty)
    }

    @Test("Single skill behavior instructions")
    func singleSkillBehavior() {
        let task = makeTask()
        let skill = makeSkill(behaviorInstructions: "Never delete files")
        task.skills = [skill]

        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions == "[Test Skill]:\nNever delete files")
    }

    @Test("Multiple skills concatenate instructions with double newline")
    func multipleSkillsBehavior() {
        let task = makeTask()
        let skill1 = makeSkill(name: "Skill A", behaviorInstructions: "Never delete files")
        let skill2 = makeSkill(name: "Skill B", behaviorInstructions: "Only run test commands")
        task.skills = [skill1, skill2]

        let result = TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions
        #expect(result.contains("[Skill A]:\nNever delete files"))
        #expect(result.contains("[Skill B]:\nOnly run test commands"))
        #expect(result.contains("\n\n"))
    }

    @Test("Empty behavior instructions are skipped")
    func emptyBehaviorSkipped() {
        let task = makeTask()
        let skill1 = makeSkill(behaviorInstructions: "Never delete files")
        let skill2 = makeSkill(behaviorInstructions: "")
        task.skills = [skill1, skill2]

        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions == "[Test Skill]:\nNever delete files")
    }
}

// MARK: - Snapshot Fallback

@Suite("Skill Snapshot Fallback")
struct SkillSnapshotFallbackTests {

    @Test("Detached task still resolves behavior and tools from skill snapshots")
    func detachedTaskUsesSkillSnapshots() {
        let task = makeTask()
        task.skillSnapshots = [
            SkillSnapshotConfig(
                id: UUID().uuidString,
                name: "Data Analyst",
                icon: "chart.bar",
                description: "Analyze warehouse data",
                allowedTools: ["Read", "Bash", "Glob", "Grep"],
                disallowedTools: ["Edit"],
                customTools: [],
                behaviorInstructions: "Use SQL or pandas to analyze data sources and summarize findings.",
                environmentKeys: ["BQ_PROFILE"],
                environmentValues: ["prod"],
                isGlobal: false,
                connectorIDs: nil,
                localToolIDs: nil,
                connectorSnapshots: [
                    ConnectorSnapshotConfig(
                        id: UUID().uuidString,
                        name: "Warehouse",
                        serviceType: "bigquery",
                        icon: "cylinder.split.1x2",
                        description: "BigQuery warehouse",
                        baseURL: "",
                        authMethod: "none",
                        credentialKeys: [],
                        configKeys: ["BQ_PROJECT"],
                        configValues: ["analytics-prod"],
                        isGlobal: false,
                        notes: "",
                        createdAt: nil,
                        updatedAt: nil
                    )
                ],
                localToolSnapshots: [
                    LocalToolSnapshotConfig(
                        id: UUID().uuidString,
                        name: "bq",
                        description: "BigQuery CLI",
                        icon: "terminal",
                        toolType: "cli",
                        command: "bq",
                        arguments: "",
                        isGlobal: false,
                        createdAt: nil,
                        updatedAt: nil
                    )
                ],
                createdAt: nil,
                updatedAt: nil
            )
        ]

        #expect(task.skills.isEmpty)
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("[Data Analyst]"))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("analyze data sources"))
        #expect(Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools).contains("bq"))
        #expect(Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools).contains("Bash"))
        #expect(!Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools).contains("Edit"))
        #expect(!Set(TaskCapabilityResolver(task: task).resolver.resolvedClaudeAllowedTools).contains("bq"))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables["BQ_PROFILE"] == "prod")
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables["BQ_PROJECT"] == "analytics-prod")
    }

    @Test("Live skills and detached snapshots are merged without duplication")
    func liveSkillsAndSnapshotsMerge() {
        let task = makeTask()
        let liveSkill = makeSkill(
            name: "Live Skill",
            allowedTools: ["Read"],
            behaviorInstructions: "Use the live skill."
        )
        task.skills = [liveSkill]
        task.skillSnapshots = [
            SkillSnapshotConfig(
                id: UUID().uuidString,
                name: "Detached Skill",
                icon: "bolt",
                description: "Detached",
                allowedTools: ["Grep"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use the detached skill.",
                environmentKeys: [],
                environmentValues: [],
                isGlobal: false,
                connectorIDs: nil,
                localToolIDs: nil,
                connectorSnapshots: nil,
                localToolSnapshots: nil,
                createdAt: nil,
                updatedAt: nil
            )
        ]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Grep"))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("[Live Skill]"))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("[Detached Skill]"))
    }
}

// MARK: - Prompt Building with Skills

@Suite("Prompt with Skills")
struct PromptWithSkillsTests {

    @Test("buildPrompt includes behavioral instructions from skills")
    func promptIncludesBehavior() {
        let task = makeTask(goal: "Fix the login bug")
        let skill = makeSkill(behaviorInstructions: "Never modify production config files")
        task.skills = [skill]

        // Replicate buildPrompt logic
        var parts: [String] = ["Goal: \(task.goal)"]
        let behaviorBlock = TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            parts.append("Behavioral Instructions (from Skills):\n\(behaviorBlock)")
        }
        let prompt = parts.joined(separator: "\n\n")

        #expect(prompt.contains("Goal: Fix the login bug"))
        #expect(prompt.contains("Behavioral Instructions (from Skills):"))
        #expect(prompt.contains("Never modify production config files"))
    }

    @Test("buildPrompt without skills has no behavioral section")
    func promptNoBehavior() {
        let task = makeTask(goal: "Fix the login bug")

        var parts: [String] = ["Goal: \(task.goal)"]
        let behaviorBlock = TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            parts.append("Behavioral Instructions (from Skills):\n\(behaviorBlock)")
        }
        let prompt = parts.joined(separator: "\n\n")

        #expect(prompt == "Goal: Fix the login bug")
        #expect(!prompt.contains("Behavioral Instructions"))
    }

    @Test("Prompt includes constraints, criteria, and behavior together")
    func promptAllSections() {
        let task = makeTask(goal: "Refactor auth module")
        task.constraints = ["No breaking changes"]
        task.acceptanceCriteria = ["All tests pass"]
        let skill = makeSkill(behaviorInstructions: "Only use Bash for tests")
        task.skills = [skill]

        var parts: [String] = ["Goal: \(task.goal)"]
        if !task.constraints.isEmpty {
            parts.append("Constraints:\n" + task.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !task.acceptanceCriteria.isEmpty {
            parts.append("Acceptance Criteria:\n" + task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        let behaviorBlock = TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions
        if !behaviorBlock.isEmpty {
            parts.append("Behavioral Instructions (from Skills):\n\(behaviorBlock)")
        }
        let prompt = parts.joined(separator: "\n\n")

        #expect(prompt.contains("Goal: Refactor auth module"))
        #expect(prompt.contains("- No breaking changes"))
        #expect(prompt.contains("- All tests pass"))
        #expect(prompt.contains("Only use Bash for tests"))
    }
}

// MARK: - Environment Variables

@Suite("Environment Variables")
struct EnvironmentVariableTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // setEnvironmentValue/environmentVariables setter need SkillSecretSeam; resolvedAllEnvironmentVariables needs ConnectorEnvironmentProjectionSeam

    @Test("Connector env vars projected through the seam match ConnectorRuntimeProjection directly")
    func resolvedAllEnvironmentVariablesMatchesDirectProjection() {
        let connector = Connector(name: "REDCap", serviceType: "redcap", baseURL: "https://redcap.example.invalid/api/")
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        connector.configKeys = ["REDCAP_PROJECT_ID"]
        connector.configValues = ["42"]

        let skill = Skill(name: "REDCap Skill", environmentVariables: ["LEGACY_KEY": "legacy-value"])
        skill.connectors = [connector]

        let viaSeam = skill.resolvedAllEnvironmentVariables
        let direct = ConnectorRuntimeProjection(connectors: [connector]).environmentVariables()

        // Every key the direct (unseamed) projection produces must appear,
        // byte-identical, in the seam-routed result - the seam is a pure
        // relay to the same underlying logic, not a reimplementation.
        for (key, value) in direct {
            #expect(viaSeam[key] == value, "mismatch for \(key)")
        }
        #expect(viaSeam["LEGACY_KEY"] == "legacy-value")
        #expect(viaSeam["REDCAP_PROJECT_ID"] == nil, "config key name is remapped via alias/prefix, not passed through verbatim")
    }

    @Test("No skills returns empty env vars")
    func noSkillsEmptyEnv() {
        let task = AgentTask(title: "Test", goal: "test")
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables.isEmpty)
    }

    @Test("Skill env vars are resolved")
    func skillEnvVars() {
        let task = AgentTask(title: "Test", goal: "test")
        let skill = Skill(
            name: "DB Skill",
            environmentVariables: ["DATABASE_URL": "postgres://localhost/test", "DB_POOL": "5"]
        )
        task.skills = [skill]

        let env = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        #expect(env["DATABASE_URL"] == "postgres://localhost/test")
        #expect(env["DB_POOL"] == "5")
    }

    @Test("Multiple skills merge env vars, later overrides")
    func mergedEnvVars() {
        let task = AgentTask(title: "Test", goal: "test")
        let skill1 = Skill(
            name: "Skill A",
            environmentVariables: ["API_URL": "https://api.example.invalid", "SHARED": "from-a"]
        )
        let skill2 = Skill(
            name: "Skill B",
            environmentVariables: ["SERVICE_MODE": "batch", "SHARED": "from-b"]
        )
        task.skills = [skill1, skill2]

        let env = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        #expect(env["API_URL"] == "https://api.example.invalid")
        #expect(env["SERVICE_MODE"] == "batch")
        // Later skill overrides
        #expect(env["SHARED"] == "from-b")
    }

    @Test("Skill env var parallel arrays stay in sync")
    func parallelArrays() {
        let skill = Skill(
            name: "Test",
            environmentVariables: ["A": "1", "B": "2"]
        )
        #expect(skill.environmentKeys.count == skill.environmentValues.count)
        #expect(skill.environmentKeys.count == 2)

        // Round-trip through computed property
        let dict = skill.environmentVariables
        #expect(dict["A"] == "1")
        #expect(dict["B"] == "2")
    }

    @Test("Setting env vars via computed property updates arrays")
    func setViaComputed() {
        let skill = Skill(name: "Test")
        skill.environmentVariables = ["TOKEN": "abc123"]
        #expect(skill.environmentKeys == ["TOKEN"])
        #expect(skill.exportableEnvironmentValues == [""])
        #expect(skill.environmentVariables["TOKEN"] == "abc123")
    }

    @Test("Bulk env var update deletes secrets dropped from the new value")
    func bulkUpdateDeletesRemovedSecret() {
        let skill = Skill(name: "Test")
        skill.environmentVariables = ["TOKEN": "abc123"]
        #expect(SkillSecretSeam.required.secretExists(key: "TOKEN", skillID: skill.id))

        // Replacing the whole dict without TOKEN should delete its Keychain
        // entry (previously silent - no audit event - see this fix's PR review).
        skill.environmentVariables = ["OTHER": "value"]
        #expect(!SkillSecretSeam.required.secretExists(key: "TOKEN", skillID: skill.id))
    }

    @Test("Empty env var skill doesn't affect resolution")
    func emptyEnvSkill() {
        let task = AgentTask(title: "Test", goal: "test")
        let skill1 = Skill(name: "A", environmentVariables: ["MODE": "val"])
        let skill2 = Skill(name: "B")
        task.skills = [skill1, skill2]

        let env = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        #expect(env["MODE"] == "val")
        #expect(env.count == 1)
    }
}

// MARK: - Preset Skills

@Suite("Preset Skills")
struct PresetSkillTests {

    @Test("Read-Only preset restricts to read tools")
    func readOnlyPreset() {
        let skill = Skill(
            name: "Read-Only",
            allowedTools: ["Read", "Glob", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: "You must not create, modify, or delete any files. Only read and analyze."
        )

        let task = makeTask()
        task.skills = [skill]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(allowed == Set(["Read", "Glob", "Grep"]))
        #expect(!allowed.contains("Write"))
        #expect(!allowed.contains("Edit"))
        #expect(!allowed.contains("Bash"))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("must not create"))
    }

    @Test("Test Runner preset allows all tools with test restriction")
    func testRunnerPreset() {
        let skill = Skill(
            name: "Test Runner",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Use Bash only to run test commands (e.g. swift test, pytest, npm test). Do not use Bash for other purposes."
        )

        let task = makeTask()
        task.skills = [skill]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(allowed == Set(Skill.defaultAllowed))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedDisallowedTools.isEmpty)
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("test commands"))
    }

    @Test("Safe Bash preset restricts dangerous commands")
    func safeBashPreset() {
        let skill = Skill(
            name: "Safe Bash",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: [],
            behaviorInstructions: "Never run rm, sudo, curl, pip install, npm install, or any destructive/network commands in Bash."
        )

        let task = makeTask()
        task.skills = [skill]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        #expect(allowed == Set(Skill.defaultAllowed))
        #expect(TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions.contains("Never run rm"))
    }

    @Test("Combining Read-Only and Safe Bash — disallowed wins")
    func combinedPresets() {
        let readOnly = Skill(
            name: "Read-Only",
            allowedTools: ["Read", "Glob", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"]
        )
        let safeBash = Skill(
            name: "Safe Bash",
            allowedTools: Skill.defaultAllowed,
            disallowedTools: []
        )

        let task = makeTask()
        task.skills = [readOnly, safeBash]

        let allowed = Set(TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools)
        // readOnly disallows Write, Edit, Bash — those should be removed even though safeBash allows them
        #expect(!allowed.contains("Write"))
        #expect(!allowed.contains("Edit"))
        #expect(!allowed.contains("Bash"))
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Glob"))
        #expect(allowed.contains("Grep"))
    }
}
