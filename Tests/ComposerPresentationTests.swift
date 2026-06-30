import Testing
@testable import ASTRA
import ASTRACore
import SwiftUI

@Suite("Composer Presentation")
struct ComposerPresentationTests {
    @Test("composer keeps compact input spacing")
    func composerKeepsCompactInputSpacing() {
        #expect(TaskComposerPresentation.usesCompactInputSpacing == true)
        #expect(TaskComposerPresentation.usesForcedExpandedInputHeight == false)
        #expect(TaskComposerPresentation.inputHorizontalPadding == 14)
        #expect(TaskComposerPresentation.inputTopPadding == 12)
        #expect(TaskComposerPresentation.inputBottomPadding == 9)
    }

    @Test("task decision dock stays compact")
    func taskDecisionDockStaysCompact() {
        #expect(TaskComposerPresentation.decisionRowUsesNestedChrome == false)
        #expect(TaskComposerPresentation.decisionRowUsesNestedStroke == false)
        #expect(TaskComposerPresentation.decisionDetailsUsePopover == true)
        #expect(TaskComposerPresentation.decisionActionsUseOverflowMenu == false)
        #expect(TaskComposerPresentation.decisionUtilitiesStayLeftAligned == true)
        #expect(TaskComposerPresentation.decisionSummaryVisibleInCompactRow == false)
        #expect(TaskComposerPresentation.decisionRowHorizontalPadding == 12)
        #expect(TaskComposerPresentation.decisionRowVerticalPadding == 10)
        #expect(TaskComposerPresentation.decisionAccentWidth == 3)
        #expect(TaskComposerPresentation.decisionIconFrame == 24)
        #expect(TaskComposerPresentation.decisionDockBottomPadding == 8)
    }

    @Test("bottom toolbar adds borders without expanding control scale")
    func bottomToolbarAddsBordersWithoutExpandingControlScale() {
        #expect(ComposerToolbarPresentation.addButtonUsesRoundedSquare == true)
        #expect(ComposerToolbarPresentation.addButtonUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.addButtonUsesBackgroundFill == false)
        #expect(ComposerToolbarPresentation.runtimePillUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.runtimePillUsesBackgroundFill == false)
        #expect(ComposerToolbarPresentation.taskStatusPillUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.menuControlsUsePlainButtonStyle == true)
        #expect(ComposerToolbarPresentation.addButtonSize == 30)
        #expect(ComposerToolbarPresentation.submitButtonSize == 30)
        #expect(ComposerToolbarPresentation.verticalPadding == 7)
        #expect(ComposerToolbarPresentation.chipVerticalPadding == 6)
        #expect(ComposerToolbarPresentation.permissionModeUsesFlatChrome == true)
    }

    @Test("provider menu shows registered providers after readiness loads")
    func providerMenuShowsRegisteredProvidersAfterReadinessLoads() {
        let runtimes: [AgentRuntimeID] = [.claudeCode, .copilotCLI, .localMLX]
        let loaded = ComposerToolbarPresentation.providerMenuRuntimes(
            from: [
                .claudeCode: .ready,
                .copilotCLI: .blocked,
                .localMLX: .warning
            ],
            registeredRuntimes: runtimes
        )

        #expect(ComposerToolbarPresentation.providerMenuRuntimes(from: [:], registeredRuntimes: runtimes).isEmpty)
        #expect(loaded == runtimes)
        #expect(ComposerToolbarPresentation.runtimeMenuStatusLabel(for: .ready) == "Ready")
        #expect(ComposerToolbarPresentation.runtimeMenuStatusLabel(for: .warning) == "Review")
        #expect(ComposerToolbarPresentation.runtimeMenuStatusLabel(for: .blocked) == "Setup needed")
        #expect(ComposerToolbarPresentation.runtimeMenuDisplayName(.localMLX, localAgentEnabled: false) == "Local MLX (Local Chat)")
        #expect(ComposerToolbarPresentation.runtimeMenuDisplayName(.localMLX, localAgentEnabled: true) == "Local MLX (Local Agent)")
        #expect(ComposerToolbarPresentation.runtimeMenuDisplayName(.claudeCode) == "Claude Code")
    }

    @Test("provider menu explains Local Chat and Local Agent scope")
    func providerMenuExplainsLocalChatAndLocalAgentScope() {
        let chatHelp = ComposerToolbarPresentation.runtimeMenuHelp(
            .localMLX,
            state: .ready,
            model: "Qwen/Qwen3-4B-MLX-4bit",
            budget: 1_000,
            enforcementMode: .warning,
            localAgentEnabled: false
        )
        #expect(chatHelp.contains("Private Local Chat"))
        #expect(chatHelp.contains("analyzes text you provide"))
        #expect(chatHelp.contains("cannot use ASTRA tools"))
        #expect(chatHelp.contains("artifacts"))

        let agentHelp = ComposerToolbarPresentation.runtimeMenuHelp(
            .localMLX,
            state: .ready,
            model: "Qwen/Qwen3-4B-MLX-4bit",
            budget: 1_000,
            enforcementMode: .warning,
            localAgentEnabled: true,
            localAgentCapabilities: .all
        )
        #expect(agentHelp.contains("Local Agent is experimental"))
        #expect(agentHelp.contains("enabled ASTRA-brokered tools"))
        #expect(agentHelp.contains("scoped file edits"))
        #expect(agentHelp.contains("shell commands"))
        #expect(agentHelp.contains("network fetches"))
        #expect(agentHelp.contains("browser clicks"))
        #expect(agentHelp.contains("browser typing"))
        #expect(agentHelp.contains("Other browser page changes remain disabled"))

        let setupHelp = ComposerToolbarPresentation.runtimeMenuHelp(
            .localMLX,
            state: .blocked,
            model: "Qwen/Qwen3-4B-MLX-4bit",
            budget: 1_000,
            enforcementMode: .warning,
            localAgentEnabled: true
        )
        #expect(setupHelp.contains("Local MLX (Local Agent) setup is not ready"))
    }

    @Test("Local MLX task status explains chat and agent stops")
    func localMLXTaskStatusExplainsChatAndAgentStops() {
        let chatBlocked = ComposerToolbarPresentation.localMLXTaskStatusOverride(
            taskStatus: .pendingUser,
            runStatus: .failed,
            stopReason: TextOnlyRuntimeGuard.stopReason
        )
        #expect(chatBlocked?.label == "Local Chat")
        #expect(chatBlocked?.help.contains("text-only") == true)

        let approval = ComposerToolbarPresentation.localMLXTaskStatusOverride(
            taskStatus: .pendingUser,
            runStatus: .failed,
            stopReason: "permission_approval_required"
        )
        #expect(approval?.label == "Approval needed")
        #expect(approval?.help.contains("Local Agent") == true)

        let missingObservation = ComposerToolbarPresentation.localMLXTaskStatusOverride(
            taskStatus: .pendingUser,
            runStatus: .failed,
            stopReason: "local_agent_missing_tool_observation"
        )
        #expect(missingObservation?.label == "Blocked")
        #expect(missingObservation?.help.contains("tool observation") == true)

        let toolBudget = ComposerToolbarPresentation.localMLXTaskStatusOverride(
            taskStatus: .pendingUser,
            runStatus: .failed,
            stopReason: "local_agent_tool_budget_exceeded"
        )
        #expect(toolBudget?.label == "Tool budget")
        #expect(toolBudget?.help.contains("tool-call limit") == true)

        let unrelated = ComposerToolbarPresentation.localMLXTaskStatusOverride(
            taskStatus: .failed,
            runStatus: .failed,
            stopReason: "provider_exit"
        )
        #expect(unrelated == nil)
    }

    @Test("slash menu follows compact command list presentation")
    func slashMenuFollowsCompactCommandListPresentation() {
        #expect(SlashCommandMenuPresentation.rowHeight == 46)
        #expect(SlashCommandMenuPresentation.iconFrame == 28)
        #expect(SlashCommandMenuPresentation.iconSize == 15)
        #expect(SlashCommandMenuPresentation.horizontalPadding == 12)
        #expect(SlashCommandMenuPresentation.verticalPadding == 6)
        #expect(SlashCommandMenuPresentation.commandFontSize == 14)
        #expect(SlashCommandMenuPresentation.titleFontSize == 12)
        #expect(SlashCommandMenuPresentation.descriptionFontSize == 11)
        #expect(SlashCommandMenuPresentation.descriptionLineLimit == 1)
        #expect(SlashCommandMenuPresentation.maxWidth == 380)
        #expect(SlashCommandMenuPresentation.usesIconColumnDividers == true)
        #expect(SlashCommandMenuPresentation.usesFullWidthDividers == false)
        #expect(SlashCommandMenuPresentation.shadowRadius == 8)
        #expect(SlashCommandMenuPresentation.shadowOpacity == 0.08)
    }

    @Test("disabled budgets are omitted from composer runtime status")
    func disabledBudgetsAreOmittedFromComposerRuntimeStatus() {
        #expect(!RuntimeBudgetPresentation.isEnabled(0))
        #expect(RuntimeBudgetPresentation.isEnabled(25_000))
        #expect(RuntimeBudgetPresentation.settingsLabel(for: 0) == "Disabled")
        #expect(RuntimeBudgetPresentation.settingsLabel(for: 25_000) == "25k tokens")
        #expect(RuntimeBudgetPresentation.compactLabel(for: 25_000) == "25k")

        let disabledStatus = RuntimeBudgetPresentation.runtimeStatusText(
            runtimeName: "Antigravity",
            modelName: "Gemini 3.5 Flash",
            budget: 0,
            includeRuntime: true
        )
        let enabledStatus = RuntimeBudgetPresentation.runtimeStatusText(
            runtimeName: "Antigravity",
            modelName: "Gemini 3.5 Flash",
            budget: 25_000,
            includeRuntime: true
        )
        let disabledHelp = RuntimeBudgetPresentation.runtimeStatusHelp(
            runtimeName: "Antigravity",
            modelName: "Gemini 3.5 Flash",
            budget: 0,
            enforcementLabel: "Warning Only"
        )

        #expect(disabledStatus == "Antigravity · Gemini 3.5 Flash")
        #expect(enabledStatus == "Antigravity · Gemini 3.5 Flash · 25k")
        #expect(disabledHelp == "Antigravity · Gemini 3.5 Flash")
    }

    @Test("task composer slash options are centralized")
    func taskComposerSlashOptionsAreCentralized() {
        #expect(TaskComposerCoordinator.shouldShowSlashMenu(messageText: "/rem"))
        #expect(!TaskComposerCoordinator.shouldShowSlashMenu(messageText: "/remember this"))

        #expect(TaskComposerCoordinator.visibleSlashOptions(messageText: "/r") == [
            TaskComposerSlashOption(id: .remember, command: "/remember "),
            TaskComposerSlashOption(id: .routine, command: "/routine "),
            TaskComposerSlashOption(id: .recap, command: "/recap")
        ])
        #expect(TaskComposerCoordinator.visibleSlashOptions(messageText: "/sch") == [
            TaskComposerSlashOption(id: .routine, command: "/routine ")
        ])
        #expect(TaskComposerCoordinator.visibleSlashOptions(messageText: "/m") == [
            TaskComposerSlashOption(id: .mcp, command: "/mcp ")
        ])
        #expect(TaskComposerSlashOption(id: .recap, command: "/recap").executesImmediately)
    }

    @Test("chat panel slash catalog exposes MCP review command")
    func chatPanelSlashCatalogExposesMCPReviewCommand() {
        let mcpOptions = ChatPanelSlashOption.matching("/m")

        #expect(mcpOptions.map(\.command) == ["/mcp"])
        #expect(mcpOptions.first?.title == "Install MCP")
        #expect(mcpOptions.first?.description.contains("server JSON") == true)
        #expect(mcpOptions.first?.executesImmediately == false)
    }

    @Test("chat panel slash catalog lists every workspace command in menu order")
    func chatPanelSlashCatalogListsEveryWorkspaceCommandInMenuOrder() {
        #expect(ChatPanelSlashOption.all.map(\.command) == [
            "/skill",
            "/tool",
            "/connector",
            "/template",
            "/app",
            "/mcp",
            "/routine",
            "/remember",
            "/recap"
        ])
        #expect(Set(ChatPanelSlashOption.all.map(\.id)).count == ChatPanelSlashOption.all.count)
        #expect(ChatPanelSlashOption.matching("/").map(\.command) == ChatPanelSlashOption.all.map(\.command))
        #expect(ChatPanelSlashOption.matching("/r").map(\.command) == ["/routine", "/remember", "/recap"])
    }

    @Test("chat panel slash routing recognizes every command and rejects lookalikes")
    func chatPanelSlashRoutingRecognizesEveryCommandAndRejectsLookalikes() {
        for command in ["/skill", "/tool", "/connector", "/template", "/app", "/mcp", "/routine", "/schedule", "/remember", "/recap"] {
            #expect(ChatPanelSlashCommandRouting.isSlashCommandInput(command))
            #expect(ChatPanelSlashCommandRouting.isSlashCommandInput("\(command) with details"))
        }

        #expect(!ChatPanelSlashCommandRouting.isSlashCommandInput("/application build"))
        #expect(!ChatPanelSlashCommandRouting.isSlashCommandInput("/remembered fact"))
        #expect(!ChatPanelSlashCommandRouting.isSlashCommandInput("please /recap this"))
    }

    @Test("chat panel slash routing separates provider assisted commands from direct commands")
    func chatPanelSlashRoutingSeparatesProviderAssistedCommandsFromDirectCommands() {
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/skill") == "/skill")
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/tool add jq") == "/tool")
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/connector") == "/connector")
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/template") == "/template")
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/routine daily cleanup") == "/routine")
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/schedule daily cleanup") == "/schedule")

        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/remember facts") == nil)
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/app build tracker") == nil)
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/mcp npx -y @acme/mcp") == nil)
        #expect(ChatPanelSlashCommandRouting.providerContextCommand(for: "/recap") == nil)
    }

    @Test("chat panel slash selection keeps commands that need arguments editable")
    func chatPanelSlashSelectionKeepsCommandsThatNeedArgumentsEditable() {
        let mcp = ChatPanelSlashOption.all.first { $0.command == "/mcp" }
        let skill = ChatPanelSlashOption.all.first { $0.command == "/skill" }

        #expect(mcp.map { ChatPanelSlashCommandRouting.selectionText(for: $0) } == "/mcp ")
        #expect(skill.map { ChatPanelSlashCommandRouting.selectionText(for: $0) } == "/skill")
    }

    @Test("task composer send action classifies commands and attachments")
    func taskComposerSendActionClassifiesCommandsAndAttachments() {
        #expect(TaskComposerCoordinator.sendAction(messageText: "   ", attachedFiles: []) == .none)
        #expect(TaskComposerCoordinator.sendAction(messageText: "/remember  prefer concise PRs  ", attachedFiles: []) == .remember("prefer concise PRs"))
        #expect(TaskComposerCoordinator.sendAction(messageText: "/recap please", attachedFiles: []) == .recap)
        #expect(TaskComposerCoordinator.sendAction(messageText: "/routine every morning", attachedFiles: []) == .routine(instructions: "every morning"))
        #expect(TaskComposerCoordinator.sendAction(messageText: "/schedule", attachedFiles: []) == .routine(instructions: nil))
        guard case .mcpInstall(let request) = TaskComposerCoordinator.sendAction(
            messageText: "/mcp npx -y @acme/mcp@1.0.0",
            attachedFiles: []
        ) else {
            Issue.record("Expected /mcp to route to MCP install review")
            return
        }
        #expect(request.intent.installSource?.identifier == "@acme/mcp")
        guard case .mcpInstallFailure(let missingWorkspaceMessage) = TaskComposerCoordinator.sendAction(
            messageText: "/mcp npx -y @acme/mcp@1.0.0",
            attachedFiles: [],
            hasWorkspace: false
        ) else {
            Issue.record("Expected /mcp to require a workspace before review")
            return
        }
        #expect(missingWorkspaceMessage == "Select a workspace first - MCP capabilities are workspace-scoped.")
        guard case .mcpInstallFailure(let parseMessage) = TaskComposerCoordinator.sendAction(
            messageText: "/mcp",
            attachedFiles: []
        ) else {
            Issue.record("Expected invalid /mcp input to return the parser failure")
            return
        }
        #expect(parseMessage.contains("Supported MCP install target formats"))
        #expect(TaskComposerCoordinator.sendAction(messageText: "Review this", attachedFiles: ["/tmp/a.txt", "/tmp/b.png"]) == .message("""
        Review this

        Attached files:
        - /tmp/a.txt
        - /tmp/b.png
        """))
    }

    @Test("task composer runtime update normalizes selected runtime model")
    func taskComposerRuntimeUpdateNormalizesSelectedRuntimeModel() {
        let cacheJSON = #"{"runtimeID":"copilot_cli","models":["gpt-5.1"],"checkedAt":0,"authority":"authoritative"}"#
        let update = TaskComposerCoordinator.runtimeUpdate(
            previousRuntime: AgentRuntimeID.claudeCode.rawValue,
            selectedRuntime: AgentRuntimeID.copilotCLI.rawValue,
            currentModel: AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode),
            cache: RuntimeModelAvailabilityCache(
                cachedClaudeModelsJSON: "",
                cachedCopilotModelsJSON: cacheJSON
            )
        )

        #expect(update.previousRuntime == AgentRuntimeID.claudeCode.rawValue)
        #expect(update.runtime == AgentRuntimeID.copilotCLI.rawValue)
        #expect(update.resolvedModel == "gpt-5.1")
        #expect(update.modelChanged)
    }
}
