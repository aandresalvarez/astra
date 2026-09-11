import Foundation
import ASTRACore
import ASTRAModels
import ASTRALogging

/// The Shelf browser half of the prompt: the session block naming the
/// `astra-browser` command catalog, and the read-only mail rider that rides on
/// top of it.
///
/// Extracted from `AgentPromptBuilder` rather than grown there. Both sections
/// are gated on the same question the launch asks, and that question needed the
/// runtime and its capability profile threaded in — growth the prompt builder's
/// line budget had no room for, and which belongs next to the gate anyway.
@MainActor
enum ShelfBrowserPromptSection {
    /// The block, and the mail rider when the turn earns it - or nothing,
    /// when this run has no way to reach the bridge either would describe.
    ///
    /// `ShelfBrowserBridgeRegistry` answers "is a Shelf browser bound to this
    /// task", which is a question about the *window*, not about the process.
    /// `CopilotCLIRuntimeAdapter` launched without `--additional-mcp-config`
    /// has neither a shell tool nor a browser MCP route, so
    /// `removingUndeliverableOfferedBridge` strips `ASTRA_BROWSER_URL` from the
    /// environment before the process ever starts. Describing the catalog to
    /// that run spends about thirty lines of context telling the agent about an
    /// endpoint it did not receive and commands it cannot invoke.
    ///
    /// The block is phrased runtime-conditionally, so it is not false — but a
    /// prompt that hedges is still the prompt describing the run from a static
    /// capability table instead of from what the launch attached. Sharing
    /// `canCarryBridge` with the launch drop, the offered-tier list in
    /// `OfferedToolRoutes`, and the plan entry in `TaskLaunchResourceResolver`
    /// is what keeps the four from answering differently.
    static func sections(
        for task: AgentTask,
        contextText: String,
        enabledBrowserAdapters: [String],
        runtime: AgentRuntimeID,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile?
    ) -> [PromptContextSection] {
        guard TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) else { return [] }
        guard BrowserBridgeRuntimeLaunchGuard.canCarryBridge(
            runtime: runtime,
            runtimeCapabilityProfile: runtimeCapabilityProfile
        ) else {
            // The registry's own `prompt_context_requested` never fires on this
            // path, so without this the block's absence looks identical to a
            // Shelf that was simply closed.
            AppLogger.audit(.shelfBrowserContext, category: "Browser", taskID: task.id, fields: [
                "event": "prompt_context_dropped",
                "reason": BrowserBridgeRuntimeLaunchGuard.missingBrowserControlToolReason,
                "runtime": runtime.rawValue
            ])
            return []
        }
        let override = enabledBrowserAdapters.isEmpty ? nil : enabledBrowserAdapters
        guard let browserContext = ShelfBrowserBridgeRegistry.shared.promptContext(
            for: task.id,
            enabledBrowserAdapters: override
        ) else { return [] }

        var sections = [PromptContextSection(
            kind: .browser,
            text: browserContext,
            sourcePointers: [PromptContextSourcePointer(
                label: "live browser bridge",
                target: "astra-browser snapshot/read-page for task \(task.id.uuidString)"
            )]
        )]
        if MailTaskIntent.isReadOnlyMailRequest([
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " ")
        ]) {
            sections.append(PromptContextSection(
                kind: .browser,
                text: mailReadSafety,
                sourcePointers: [PromptContextSourcePointer(label: "mail read safety", target: "current task intent")]
            ))
        }
        return sections
    }

    private static let mailReadSafety = """
    Mail Read Safety:
    The current task is a read-only mail request. If a read-only mail helper is available in the listed tools, use it before browser scraping: `stanford-mail`, `stanford-graph-mail`, or `stanford-apple-mail`.
    If only the browser is available, treat Outlook/mail pages as read-only evidence. Use `astra-browser read-page` and `analyze` for inspection, ignore reminders/toasts/calendar panes unless the user asked about them, and verify that any opened message subject/sender matches the requested inbox item before summarizing.
    Do not click Reply, Reply all, Forward, Send, Delete, Archive, Move, Mark read/unread, Junk, Report phishing, or Discard for this task. If the latest email cannot be identified from read-only evidence, ask for clarification instead of mutating the mailbox.
    """
}
