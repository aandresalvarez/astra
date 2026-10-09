import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels
import AppKit
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

    @Test("new task worktree choice sits in the composer dock strip with trailing controls")
    func newTaskWorktreeControlsAreWiredIntoComposer() throws {
        let composer = try sourceFile("Astra/Views/ChatPanelView.swift")
        // The creation flow and the cached binding live in the composer's companion.
        let creation = try sourceFile("Astra/Views/ChatPanelViewWorktreeCreation.swift")
        let strip = try sourceFile("Astra/Views/NewTaskWorktreeDockView.swift")
        let decisionDock = try sourceFile("Astra/Views/TaskDecisionDockView.swift")

        // The strip opens the composer card, where an open task shows its
        // decision dock, and owns the setup progress and creation problems.
        let stripCall = try #require(composer.range(of: "NewTaskWorktreeDockView("))
        let input = try #require(composer.range(of: "TextField(\"Describe a task or ask a question...\""))
        #expect(stripCall.lowerBound < input.lowerBound)
        // A draft that already has its worktree keeps it; any other may opt in.
        #expect(composer.contains("allowsChoice: allowsWorktreeChoice"))
        #expect(composer.contains("binding: worktreeBinding"))
        #expect(creation.contains("var allowsWorktreeChoice: Bool { worktreeBinding == nil }"))
        // The binding is read from disk only when the draft, its pin, or its
        // prepared event changes, never per keystroke.
        #expect(creation.contains("var worktreeBinding: TaskWorktreePayload? { cachedWorktreeBinding }"))
        #expect(composer.contains(".onChange(of: worktreeBindingSignature, initial: true) { refreshWorktreeBinding() }"))
        #expect(!composer.contains(".disabled(isPreparingWorktree)"))
        #expect(composer.contains("onCancel: cancelTaskCreation"))
        #expect(strip.contains("accessibilityIdentifier(\"NewTaskWorktreeCancel\")"))
        #expect(composer.contains("isPreparing: isPreparingWorktree"))
        #expect(composer.contains("problem: taskCreationError"))
        #expect(composer.contains("selection: $worktreeSelection"))
        #expect(composer.contains("hasInput: hasInput && canSubmitWorktreeSelection"))
        // A refused submission names why: a gone checkout, not a missing repository.
        #expect(creation.contains("worktreeSelection.submitError"))
        #expect(!composer.contains("TaskWorktreeCreationError.repositoryUnavailable"))
        #expect(!creation.contains("TaskWorktreeCreationError.repositoryUnavailable"))
        #expect(!composer.contains("NewTaskWorktreeOptionsView"))
        #expect(!composer.contains("ProgressView(\"Preparing task checkout...\")"))

        // Both strips share the dock row chrome.
        #expect(strip.contains(".composerDockRowChrome(tone: presentation.tone)"))
        #expect(decisionDock.contains(".composerDockRowChrome(tone: presentation.tone)"))
        #expect(strip.contains("SubtleDivider()"))

        // Status leads; controls trail after a spacer in both layouts.
        let row = try #require(strip.range(of: "private func dockRow("))
        let status = try #require(strip.range(of: "statusCluster(presentation)", range: row.upperBound..<strip.endIndex))
        let spacer = try #require(strip.range(of: "Spacer(minLength: 12)", range: status.upperBound..<strip.endIndex))
        let trailing = try #require(strip.range(of: "controls(presentation)", range: spacer.upperBound..<strip.endIndex))
        let compactSpacer = try #require(strip.range(of: "Spacer(minLength: 0)", range: trailing.upperBound..<strip.endIndex))
        #expect(strip.range(of: "controls(presentation)", range: compactSpacer.upperBound..<strip.endIndex) != nil)

        // The checkbox is rightmost; the repository menu appears to its left.
        let controls = try #require(strip.range(of: "private func controls("))
        let menu = try #require(strip.range(of: "repositoryMenu", range: controls.upperBound..<strip.endIndex))
        let toggle = try #require(strip.range(
            of: "Toggle(NewTaskWorktreeDockPresentation.toggleTitle, isOn: enabledBinding)",
            range: controls.upperBound..<strip.endIndex
        ))
        #expect(menu.lowerBound < toggle.lowerBound)
        #expect(strip.contains(".toggleStyle(.checkbox)"))
        // One menu holds the repository (the shared code location) and the base.
        let repositorySection = try #require(strip.range(of: "Section(NewTaskWorktreeDockPresentation.repositorySectionTitle)"))
        let baseSection = try #require(strip.range(of: "Section(NewTaskWorktreeDockPresentation.baseSectionTitle)"))
        #expect(repositorySection.lowerBound < baseSection.lowerBound)
        #expect(strip.contains("selectRepository(repository)"))
        #expect(strip.contains("TaskCodeLocationPin.set(repository.path"))
        // Picking the selected repository again replaces a gone checkout.
        #expect(strip.contains("selection.isNewChoice(repository)"))
        #expect(strip.contains("selection.choose(repository)"))
        #expect(strip.contains("selection: baseBinding"))
        #expect(strip.contains("updateChoice { $0.isEnabled = value }"))
        #expect(strip.contains("updateChoice { $0.base = value }"))
        #expect(strip.contains("NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: modelContext)"))
        #expect(strip.contains("choiceProblem = error.localizedDescription"))
        #expect(strip.contains(".pickerStyle(.inline)"))
        #expect(strip.contains(".menuStyle(.button)"))
        #expect(NewTaskWorktreeDockPresentation.toggleTitle == "Start in a new worktree")
    }

    @Test("composer dock strips share one tone palette")
    func composerDockStripsShareTonePalette() {
        #expect(TaskDecisionDockTone.neutral.dockColor == Stanford.coolGrey)
        #expect(TaskDecisionDockTone.running.dockColor == Stanford.lagunita)
        #expect(TaskDecisionDockTone.attention.dockColor == Stanford.poppy)
        #expect(TaskDecisionDockTone.failed.dockColor == Stanford.failed)
        for tone in [TaskDecisionDockTone.success, .verified, .closed] {
            #expect(tone.dockColor == Stanford.statusHealthy)
        }
        #expect(TaskDecisionDockTone.running.dockStatusIconColor == Stanford.statusInfo)
        #expect(TaskDecisionDockTone.failed.dockStatusIconColor == Stanford.failed)
    }

    @Test("planning context uses the prepared checkout before either provider call")
    func planningContextUsesPreparedWorktree() throws {
        let composer = try sourceFile("Astra/Views/ChatPanelView.swift")
        for method in ["private func sendMessage()", "private func generatePlanFromConversation()"] {
            let start = try #require(composer.range(of: method))
            let call = try #require(composer.range(
                of: "let result = await SpecEngine.chat(",
                range: start.upperBound..<composer.endIndex
            ))
            let preparation = String(composer[start.upperBound..<call.lowerBound])
            let save = try #require(preparation.range(of: "let planningDraft = try await saveDraft()"))
            let context = try #require(preparation.range(of: "baseNewTaskSkillContext(for: planningDraft)"))
            #expect(save.lowerBound < context.lowerBound)
        }
        #expect(composer.contains("task.map { TaskWorkspaceAccess(task: $0).runtimeWorkspaceFolders }"))
        #expect(composer.contains("TaskWorkspaceAccess(task: $0).runtimeReadOnlyWorkspaceFolders.map(\\.path)"))
        #expect(composer.contains("readOnlyPaths.contains(descriptor.path) ? \" (read-only)\" : \"\""))
    }

    @Test("switching workspaces detaches creation and stops old chat and planning work")
    func composerSwitchCancelsOldWorkspaceOperations() throws {
        let composer = try sourceFile("Astra/Views/ChatPanelView.swift")
        let start = try #require(composer.range(of: ".onChange(of: workspace?.persistentModelID)"))
        let end = try #require(composer.range(of: "// MARK: - Scroll behavior", range: start.upperBound..<composer.endIndex))
        let handler = composer[start.upperBound..<end.lowerBound]
        #expect(handler.contains("chatReplyTask?.cancel()"))
        #expect(handler.contains("planGenerationTask?.cancel()"))
        #expect(handler.contains("taskCreation.detach()"))
        #expect(handler.contains("if draftTask?.workspace?.id != workspace?.id { draftTask = nil }"))
        #expect(composer.contains("defer { if !Task.isCancelled { isThinking = false } }"))
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
        #expect(TaskComposerPresentation.decisionRowVerticalPadding == 7)
        #expect(TaskComposerPresentation.decisionAccentWidth == 3)
        #expect(TaskComposerPresentation.decisionIconFrame == 16)
        #expect(TaskComposerPresentation.decisionDockBottomPadding == 6)
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

    /// The provider/model chip once stretched to about half the composer: a
    /// borderless Menu is greedy and shared the toolbar's spare width with the
    /// Spacer. A hosted NSHostingView cannot reproduce that (the chip measures
    /// the same with and without the modifier), so this pins the shape of the
    /// chain instead; the behaviour is checked in ASTRA Dev.app.
    @Test("provider and model chip hugs its label instead of stretching")
    func runtimeChipHugsItsLabel() throws {
        let source = try sourceFile("Astra/Views/Components/ComposerToolbar.swift")
        let start = try #require(source.range(of: "private func providerModelPill"))
        let end = try #require(source.range(of: "// MARK: - Model selector popover", range: start.upperBound..<source.endIndex))
        let chip = String(source[start.lowerBound..<end.lowerBound])

        let fit = try #require(chip.range(of: ".fixedSize(horizontal: true, vertical: false)"))
        let padding = try #require(chip.range(of: ".padding(.horizontal"))
        #expect(fit.lowerBound < padding.lowerBound, "fit the Menu before padding and chrome are applied")
    }

    @Test("composer keeps Auto separate from execution sandbox state")
    func composerSeparatesAutoFromExecutionSandbox() {
        #expect(ComposerToolbarPresentation.permissionModeLabel(for: .autonomous) == "Auto")
        #expect(ComposerToolbarPresentation.permissionModeHelp(for: .autonomous).contains("independently controls OS isolation"))
        #expect(ComposerToolbarPresentation.permissionModeLabel(for: .review) == "Ask")
    }

    @Test("chat transcript bubbles are shared across chat surfaces")
    func chatTranscriptBubblesAreSharedAcrossChatSurfaces() throws {
        let chatPanel = try sourceFile("Astra/Views/ChatPanelView.swift")
        let taskMain = try sourceFile("Astra/Views/TaskMainView.swift")
        let appStudio = try sourceFile("Astra/Views/WorkspaceAppStudioChatView.swift")

        #expect(chatPanel.contains("ChatTranscriptUserBubble("))
        #expect(taskMain.contains("ChatTranscriptUserBubble("))
        #expect(appStudio.contains("ChatTranscriptCompactBubble("))
        #expect(chatPanel.contains("ComposerPasteIntake.intake("))
        #expect(taskMain.contains("ComposerPasteIntake.intake("))
    }

    @Test("composer paste intake classifies native text and file attachments")
    func composerPasteIntakeClassifiesNativeTextAndFileAttachments() {
        let multilineText = Array(repeating: "review this line", count: 11).joined(separator: "\n")
        let longPlainText = String(repeating: "plain", count: 101)
        let longJSONText = "  {\n" + String(repeating: "\"key\": true,\n", count: 45) + "\"done\": true\n}"
        let longArrayText = "\n[\n" + String(repeating: "\"item\",\n", count: 80) + "\"done\"\n]"

        #expect(!ComposerPasteIntake.shouldAttachText("short inline paste"))
        #expect(ComposerPasteIntake.shouldAttachText(multilineText))
        #expect(ComposerPasteIntake.shouldAttachText(longPlainText))
        #expect(ComposerPasteIntake.textAttachmentExtension(for: multilineText) == "txt")
        #expect(ComposerPasteIntake.textAttachmentExtension(for: longPlainText) == "txt")
        #expect(ComposerPasteIntake.textAttachmentExtension(for: longJSONText) == "json")
        #expect(ComposerPasteIntake.textAttachmentExtension(for: longArrayText) == "json")
    }

    @Test("composer paste intake attaches long text without taking over short native text")
    func composerPasteIntakeAttachesLongTextWithoutTakingOverShortNativeText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("astra.composer-paste-intake.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("short inline text", forType: .string)

        let shortResult = ComposerPasteIntake.intake(pasteboard: pasteboard, existingAttachments: [])
        #expect(!shortResult.handled)
        #expect(shortResult.attachmentPaths.isEmpty)

        let longJSONText = "  {\n" + String(repeating: "\"key\": true,\n", count: 45) + "\"done\": true\n}"
        pasteboard.clearContents()
        pasteboard.setString(longJSONText, forType: .string)

        let longResult = ComposerPasteIntake.intake(pasteboard: pasteboard, existingAttachments: [])
        #expect(longResult.handled)
        let attachmentPath = try #require(longResult.attachmentPaths.first)
        defer { try? FileManager.default.removeItem(atPath: attachmentPath) }
        #expect(attachmentPath.hasSuffix(".json"))
        #expect(try String(contentsOfFile: attachmentPath, encoding: .utf8) == longJSONText)
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

    /// The follow-up send classifies with the composer's paths, then sends a
    /// message recomposed from durable copies; both must share one format.
    @Test("task composer message composition matches the classified send action")
    func taskComposerMessageCompositionMatchesSendAction() {
        let files = ["/tmp/a.txt", "/tmp/b.png"]
        #expect(TaskComposerCoordinator.sendAction(messageText: "Review this", attachedFiles: files)
            == .message(TaskComposerCoordinator.composedMessage(messageText: "Review this", attachedFiles: files)))
        #expect(TaskComposerCoordinator.composedMessage(messageText: "Review this ", attachedFiles: []) == "Review this ")
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

    @Test("applyRuntimeSwitch marks the task explicitly selected so the launch resolver respects it")
    @MainActor
    func applyRuntimeSwitchMarksTaskExplicitlySelected() {
        let task = AgentTask(title: "Switch target", goal: "test", runtime: .cursorCLI)
        #expect(task.runtimeExplicitlySelected == false)

        TaskComposerCoordinator.applyRuntimeSwitch(
            to: AgentRuntimeID.codexCLI.rawValue,
            task: task,
            cache: RuntimeModelAvailabilityCache(cachedClaudeModelsJSON: "", cachedCopilotModelsJSON: ""),
            source: "policy_block_switch_action"
        )

        #expect(task.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.runtimeExplicitlySelected == true)
    }

    @Test("explicit runtime selection is sticky-true across a draft resync")
    func explicitRuntimeSelectionIsStickyTrueAcrossDraftResync() {
        // ChatPanelView's inline "new task" composer has its own draft-task
        // lifecycle distinct from TaskComposerCoordinator.applyRuntimeSwitch's
        // single-task case: saveDraft() re-derives runtimeID from the composer's
        // live AppStorage default on every call, so it must never let that
        // resync silently clobber an explicit pick already recorded on the
        // draft — a resync happening after the pick is the common case, since
        // saveDraft() runs on nearly every subsequent composer action.
        #expect(TaskComposerCoordinator.explicitRuntimeSelection(existing: false, composerFlagged: false) == false)
        #expect(TaskComposerCoordinator.explicitRuntimeSelection(existing: false, composerFlagged: true) == true)
        #expect(TaskComposerCoordinator.explicitRuntimeSelection(existing: true, composerFlagged: false) == true)
        #expect(TaskComposerCoordinator.explicitRuntimeSelection(existing: true, composerFlagged: true) == true)
    }

    @Test("reasoning effort stays clearable in the composer and capability-gated in settings")
    func reasoningEffortSurfacesStayReachable() throws {
        let toolbar = try sourceFile("Astra/Views/Components/ComposerToolbar.swift")
        // `nil` is how a task says "let the provider decide". Without an entry
        // that sends it, a task given an explicit effort could never be handed
        // back — every other entry sets a concrete value.
        #expect(toolbar.contains("onReasoningEffortChange?(nil)"))

        // The settings picker has to be a sibling of the provider branch, not
        // nested in its `else`: Claude declares `supportsReasoningEffort` too,
        // and the `else` runs only for the runtimes that are not Claude.
        let settings = try sourceFile("Astra/Views/SettingsRuntimeTab.swift")
        let branchIndent = "\n                "
        #expect(settings.contains("\(branchIndent)if runtime == .claudeCode {"))
        #expect(settings.contains(
            "\(branchIndent)if AgentRuntimeAdapterRegistry.descriptor(for: runtime).supportsReasoningEffort {"
        ))
    }

    /// The composer's effort lives in one global preference shared by every
    /// runtime it can switch to, so a pick always outlives the model it was
    /// made for. Every surface that persists it has to resolve it against the
    /// runtime and model it is persisting alongside.
    @Test("composer effort writes resolve against the selection and reach the draft")
    func composerEffortWritesResolveAgainstSelection() throws {
        let chat = try sourceFile("Astra/Views/ChatPanelView.swift")
        let writes = chat
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(".reasoningEffort = ") }
        #expect(writes.count >= 6)
        for write in writes {
            #expect(
                write.contains("composerReasoningEffort(")
                    || write.contains("= effort")
                    || write.contains("= resolved"),
                "effort written without resolving it: \(write.trimmingCharacters(in: .whitespaces))"
            )
        }

        // runApprovedPlan() submits draftTask without a fresh saveDraft(), so a
        // pick landing after the draft exists has to reach the draft directly —
        // both when the user makes it and when a switch re-resolves it.
        #expect(chat.contains("draftTask?.reasoningEffort = effort"))
        #expect(chat.contains("draftTask?.reasoningEffort = resolved"))
        // The existing-draft branch of saveDraft() keeps it in step from then on.
        #expect(chat.contains("draft.reasoningEffort = composerReasoningEffort("))

        // "" is the stored form of "let the provider decide". Without a row
        // that writes it, Settings cannot walk an explicit level back.
        let settings = try sourceFile("Astra/Views/SettingsRuntimeTab.swift")
        #expect(settings.contains(
            "Picker(\"Default Reasoning Effort\", selection: $defaultReasoningEffortRaw)"
        ))
        #expect(settings.contains(".tag(\"\")"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
