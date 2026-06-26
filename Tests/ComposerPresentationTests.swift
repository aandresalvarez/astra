import Testing
@testable import ASTRA
import ASTRACore

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
        #expect(TaskComposerSlashOption(id: .recap, command: "/recap").executesImmediately)
    }

    @Test("task composer send action classifies commands and attachments")
    func taskComposerSendActionClassifiesCommandsAndAttachments() {
        #expect(TaskComposerCoordinator.sendAction(messageText: "   ", attachedFiles: []) == .none)
        #expect(TaskComposerCoordinator.sendAction(messageText: "/remember  prefer concise PRs  ", attachedFiles: []) == .remember("prefer concise PRs"))
        #expect(TaskComposerCoordinator.sendAction(messageText: "/recap please", attachedFiles: []) == .recap)
        #expect(TaskComposerCoordinator.sendAction(messageText: "/routine every morning", attachedFiles: []) == .routine(instructions: "every morning"))
        #expect(TaskComposerCoordinator.sendAction(messageText: "/schedule", attachedFiles: []) == .routine(instructions: nil))
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
