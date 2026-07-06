import Testing
import Foundation
import ASTRAModels
@testable import ASTRA

@Suite("Tool Wizard – Full Functional Flow")
struct ToolWizardFunctionalTests {

    // MARK: - Wizard Step-Through

    @Test("Wizard collects all 4 tool fields via processInput")
    func wizardCollectsAllFields() {
        var wizard = SlashWizard(type: .tool)
        #expect(wizard.step == 0)
        #expect(!wizard.isComplete)

        // Step 0 → name
        let r0 = wizard.processInput("jq-formatter")
        #expect(r0 != nil)
        #expect(wizard.collected["name"] == "jq-formatter")
        #expect(wizard.step == 1)

        // Step 1 → type (numeric shortcut "1" = cli)
        let r1 = wizard.processInput("1")
        #expect(r1 != nil)
        #expect(wizard.collected["type"] == "cli")
        #expect(wizard.step == 2)

        // Step 2 → command
        let r2 = wizard.processInput("jq")
        #expect(r2 != nil)
        #expect(wizard.collected["command"] == "jq")
        #expect(wizard.step == 3)

        // Step 3 → description (nil return signals completion)
        let r3 = wizard.processInput("Format JSON with jq")
        #expect(r3 == nil)
        #expect(wizard.step == 4)
        #expect(wizard.isComplete)
    }

    @Test("Wizard type shortcuts: script and mcp")
    func wizardTypeShortcuts() {
        // Script via "2"
        var w1 = SlashWizard(type: .tool)
        _ = w1.processInput("my-script")
        _ = w1.processInput("2")
        #expect(w1.collected["type"] == "script")

        // MCP via "3"
        var w2 = SlashWizard(type: .tool)
        _ = w2.processInput("mcp-tool")
        _ = w2.processInput("3")
        #expect(w2.collected["type"] == "mcp")

        // Literal "cli"
        var w3 = SlashWizard(type: .tool)
        _ = w3.processInput("literal")
        _ = w3.processInput("cli")
        #expect(w3.collected["type"] == "cli")
    }

    @Test("Wizard prompt changes per type for step 2")
    func wizardPromptPerType() {
        var wCli = SlashWizard(type: .tool)
        _ = wCli.processInput("t")
        _ = wCli.processInput("1")
        #expect(wCli.currentPrompt.contains("CLI command"))

        var wScript = SlashWizard(type: .tool)
        _ = wScript.processInput("t")
        _ = wScript.processInput("2")
        #expect(wScript.currentPrompt.contains("path to the script"))

        var wMcp = SlashWizard(type: .tool)
        _ = wMcp.processInput("t")
        _ = wMcp.processInput("3")
        #expect(wMcp.currentPrompt.contains("MCP tool name"))
    }

    @Test("Intro message is correct for tool wizard")
    func introMessage() {
        let msg = SlashWizard.introMessage(for: .tool)
        #expect(msg.contains("tool"))
        #expect(msg.contains("4 steps"))
    }

    // MARK: - LocalTool Creation from Wizard Output

    @Test("LocalTool created from wizard collected data matches fields")
    func localToolFromWizard() {
        // Simulate a completed wizard
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("curl-fetcher")
        _ = wizard.processInput("1")
        _ = wizard.processInput("curl")
        _ = wizard.processInput("Fetch URLs with curl")
        #expect(wizard.isComplete)

        // Mirror finalizeWizard logic
        let name = wizard.collected["name"]!
        let toolType = wizard.collected["type"]!
        let command = wizard.collected["command"]!
        let desc = wizard.collected["description"]!

        let tool = LocalTool(name: name)
        tool.toolType = toolType
        tool.command = command
        tool.toolDescription = desc
        tool.icon = LocalTool.iconForType(toolType)

        #expect(tool.name == "curl-fetcher")
        #expect(tool.toolType == "cli")
        #expect(tool.command == "curl")
        #expect(tool.toolDescription == "Fetch URLs with curl")
        #expect(tool.icon == "terminal")
        #expect(tool.displayCommand == "curl")
    }

    @Test("Script tool gets correct icon")
    func scriptToolIcon() {
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("deploy")
        _ = wizard.processInput("2")
        _ = wizard.processInput("/opt/scripts/deploy.sh")
        _ = wizard.processInput("Run deployment")

        let tool = LocalTool(name: wizard.collected["name"]!)
        tool.toolType = wizard.collected["type"]!
        tool.command = wizard.collected["command"]!
        tool.icon = LocalTool.iconForType(tool.toolType)

        #expect(tool.icon == "doc.text.fill")
        #expect(tool.toolType == "script")
        #expect(tool.command == "/opt/scripts/deploy.sh")
    }

    @Test("MCP tool gets correct icon")
    func mcpToolIcon() {
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("slack-poster")
        _ = wizard.processInput("3")
        _ = wizard.processInput("mcp__slack__post_message")
        _ = wizard.processInput("Post to Slack")

        let tool = LocalTool(name: wizard.collected["name"]!)
        tool.toolType = wizard.collected["type"]!
        tool.command = wizard.collected["command"]!
        tool.icon = LocalTool.iconForType(tool.toolType)

        #expect(tool.icon == "puzzlepiece.extension")
        #expect(tool.toolType == "mcp")
    }

    // MARK: - Tool → Skill → Task Integration

    @Test("Tool attached to skill appears in allAllowedTools")
    func toolInSkillAllowedTools() {
        // Create tool from wizard output
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("jq")
        _ = wizard.processInput("1")
        _ = wizard.processInput("jq")
        _ = wizard.processInput("JSON processor")
        #expect(wizard.isComplete)

        let tool = LocalTool(name: wizard.collected["name"]!)
        tool.toolType = wizard.collected["type"]!
        tool.command = wizard.collected["command"]!
        tool.toolDescription = wizard.collected["description"]!

        // Create a skill and attach the tool
        let skill = Skill(
            name: "Data Processing",
            allowedTools: ["Read", "Bash"]
        )
        skill.localTools.append(tool)

        // Tool should appear in allAllowedTools
        let allowed = skill.allAllowedTools
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Bash"))
        #expect(allowed.contains("jq"))
    }

    @Test("Tool with empty command is excluded from allAllowedTools")
    func emptyCommandExcluded() {
        let tool = LocalTool(name: "incomplete-tool")
        // command is empty by default

        let skill = Skill(name: "Test", allowedTools: ["Read"])
        skill.localTools.append(tool)

        let allowed = skill.allAllowedTools
        #expect(allowed.contains("Read"))
        #expect(!allowed.contains("incomplete-tool"))
    }

    @Test("Tool flows through to task resolvedAllowedTools")
    func toolInTaskResolvedTools() {
        // Wizard → Tool
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("docker")
        _ = wizard.processInput("1")
        _ = wizard.processInput("docker")
        _ = wizard.processInput("Run containers")

        let tool = LocalTool(name: wizard.collected["name"]!)
        tool.toolType = wizard.collected["type"]!
        tool.command = wizard.collected["command"]!

        // Tool → Skill
        let skill = Skill(name: "DevOps", allowedTools: ["Bash", "Read"])
        skill.localTools.append(tool)

        // Skill → Task
        let task = AgentTask(title: "Deploy", goal: "Deploy the app")
        task.skills.append(skill)

        let resolved = TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools
        #expect(resolved.contains("Bash"))
        #expect(resolved.contains("Read"))
        #expect(resolved.contains("docker"))
    }

    @Test("Multiple tools from separate wizards all appear in task")
    func multipleToolsInTask() {
        // Create two tools via separate wizard flows
        let tools: [(String, String, String, String)] = [
            ("jq", "1", "jq", "JSON"),
            ("rg", "1", "rg", "Search"),
        ]

        let skill = Skill(name: "Search & Transform", allowedTools: ["Read"])

        for (name, typeChoice, cmd, desc) in tools {
            var w = SlashWizard(type: .tool)
            _ = w.processInput(name)
            _ = w.processInput(typeChoice)
            _ = w.processInput(cmd)
            _ = w.processInput(desc)
            #expect(w.isComplete)

            let t = LocalTool(name: w.collected["name"]!)
            t.toolType = w.collected["type"]!
            t.command = w.collected["command"]!
            skill.localTools.append(t)
        }

        let task = AgentTask(title: "Analyze", goal: "Analyze logs")
        task.skills.append(skill)

        let resolved = TaskCapabilityResolver(task: task).resolver.resolvedAllowedTools
        #expect(resolved.contains("jq"))
        #expect(resolved.contains("rg"))
        #expect(resolved.contains("Read"))
    }

    @Test("displayCommand includes arguments when present")
    func displayCommandWithArgs() {
        var wizard = SlashWizard(type: .tool)
        _ = wizard.processInput("formatter")
        _ = wizard.processInput("1")
        _ = wizard.processInput("prettier")
        _ = wizard.processInput("Code formatter")

        let tool = LocalTool(name: wizard.collected["name"]!)
        tool.command = wizard.collected["command"]!
        tool.arguments = "--write --single-quote"

        #expect(tool.displayCommand == "prettier --write --single-quote")
    }
}
