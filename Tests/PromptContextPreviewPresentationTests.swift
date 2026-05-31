import Testing
@testable import ASTRA

@Suite("Prompt Context Preview Presentation")
struct PromptContextPreviewPresentationTests {
    @Test("Completed tasks without draft follow-up have no pending prompt")
    func completedTasksWithoutDraftFollowUpHaveNoPendingPrompt() {
        let request = PromptContextPreviewPresentation.request(
            taskStatus: .completed,
            hasProviderSession: true,
            messageText: "",
            attachedFiles: []
        )

        #expect(request.kind == .unavailable)
        #expect(request.followUpMessage == nil)
        #expect(request.unavailableReason?.contains("No provider prompt is pending") == true)
    }

    @Test("Typed terminal task follow-up previews follow-up prompt")
    func typedTerminalTaskFollowUpPreviewsFollowUpPrompt() {
        let request = PromptContextPreviewPresentation.request(
            taskStatus: .completed,
            hasProviderSession: true,
            messageText: "Continue with the report",
            attachedFiles: ["/tmp/context.md"]
        )

        #expect(request.kind == .followUp)
        #expect(request.followUpMessage?.contains("Continue with the report") == true)
        #expect(request.followUpMessage?.contains("- /tmp/context.md") == true)
    }

    @Test("Queued tasks preview the initial run prompt")
    func queuedTasksPreviewInitialRunPrompt() {
        let request = PromptContextPreviewPresentation.request(
            taskStatus: .queued,
            hasProviderSession: false,
            messageText: "",
            attachedFiles: []
        )

        #expect(request.kind == .initialRun)
        #expect(request.followUpMessage == nil)
    }

    @Test("Stopped tasks with provider session preview resume follow-up")
    func stoppedTasksWithProviderSessionPreviewResumeFollowUp() {
        let request = PromptContextPreviewPresentation.request(
            taskStatus: .failed,
            hasProviderSession: true,
            messageText: "",
            attachedFiles: []
        )

        #expect(request.kind == .followUp)
        #expect(request.followUpMessage == PromptContextPreviewPresentation.defaultResumeMessage)
    }

    @Test("Summary reports mode, sections, tokens, and truncation")
    func summaryReportsModeSectionsTokensAndTruncation() {
        let manifest = PromptAssemblyManifest(
            mode: .followUp,
            prompt: String(repeating: "x", count: 800),
            sections: [
                PromptAssemblySectionManifest(
                    kind: .currentGoal,
                    tokenBudget: 2500,
                    estimatedOriginalTokens: 20,
                    estimatedIncludedTokens: 20,
                    originalCharacterCount: 80,
                    includedCharacterCount: 80,
                    isTruncated: false,
                    sourcePointers: [PromptAssemblySourcePointer(label: "task", target: "task-id")],
                    includedTextPreview: "Goal"
                ),
                PromptAssemblySectionManifest(
                    kind: .recentTranscript,
                    tokenBudget: 140,
                    estimatedOriginalTokens: 1000,
                    estimatedIncludedTokens: 140,
                    originalCharacterCount: 4000,
                    includedCharacterCount: 560,
                    isTruncated: true,
                    sourcePointers: [PromptAssemblySourcePointer(label: "session history", target: "/tmp/session_history.md")],
                    includedTextPreview: "Transcript"
                )
            ],
            estimatedPromptTokens: 200,
            promptCharacterCount: 800
        )

        let summary = PromptContextPreviewPresentation.summary(for: manifest)
        let transcript = manifest.sections[1]

        #expect(summary.modeText == "Follow-up")
        #expect(summary.tokenText == "200 tokens")
        #expect(summary.sectionText == "2 sections")
        #expect(summary.truncationText == "1 truncated")
        #expect(summary.characterText == "800 chars")
        #expect(PromptContextPreviewPresentation.budgetText(for: transcript) == "140 / 140")
        #expect(PromptContextPreviewPresentation.originalText(for: transcript) == "1.0k original")
        #expect(PromptContextPreviewPresentation.sourcePointerText(for: transcript) == "1 source")
        #expect(PromptContextPreviewPresentation.truncationLabel(for: transcript) == "Truncated")
    }
}
