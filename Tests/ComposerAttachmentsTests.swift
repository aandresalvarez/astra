import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// A draft keeps its attachments in `AgentTask.inputs`, while the new-task
/// composer edits them as `attachedFiles` chips and writes those back to the
/// draft. Reopening a draft used to leave the chips empty, so the next save —
/// or approving and running its plan — replaced the draft's inputs with `[]`.
@Suite("Composer attachments")
@MainActor
struct ComposerAttachmentsTests {
    /// The two ways `ChatPanelView` moves chips between itself and an existing
    /// draft; `draftComposerWiring` pins that the view makes these same calls.
    private struct DraftComposer {
        var attachedFiles: [String] = []

        /// `loadDraftMessages(_:)`.
        mutating func reopen(_ draft: AgentTask) {
            attachedFiles = ComposerAttachments.paths(in: draft.inputs)
        }

        /// `saveDraft()` on an existing draft, `approvePendingPlan()`, and `runApprovedPlan(_:)`.
        func save(into draft: AgentTask) {
            draft.inputs = ComposerAttachments.inputs(draft.inputs, replacingPathsWith: attachedFiles)
        }
    }

    @Test("a reopened draft keeps its attachments through the next save")
    func reopenedDraftKeepsAttachmentsThroughNextSave() {
        let attached = [
            "/Users/me/Documents/launch-brief.pdf",
            (NSTemporaryDirectory() as NSString).appendingPathComponent("astra_paste_1234ABCD.txt")
        ]
        let draft = AgentTask(title: "Plan the launch", goal: "Plan the launch")
        // saveDraft() creating the draft.
        draft.inputs = attached

        // A fresh composer for the same draft, as selecting it builds one.
        var reopened = DraftComposer()
        reopened.reopen(draft)
        #expect(reopened.attachedFiles == attached)

        reopened.save(into: draft)
        #expect(draft.inputs == attached)

        // And again, since saveDraft() runs after every planning reply.
        reopened.reopen(draft)
        reopened.save(into: draft)
        #expect(draft.inputs == attached)
    }

    @Test("prose inputs never become chips and survive a reopened draft's save")
    func proseInputsSurviveAReopenedDraftsSave() {
        // What WorkspaceAppActionExecutor's `task.createDraft` stores.
        let provenance = [
            "Created from Workspace App 'Grocery Planner' (grocery-planner).",
            "Workspace App action: plan-week"
        ]
        let draft = AgentTask(title: "Plan the week", goal: "Plan the week")
        draft.inputs = provenance

        var composer = DraftComposer()
        composer.reopen(draft)
        #expect(composer.attachedFiles.isEmpty)

        composer.attachedFiles.append("/Users/me/pantry.csv")
        composer.save(into: draft)
        #expect(draft.inputs == provenance + ["/Users/me/pantry.csv"])
    }

    @Test("removing a chip drops only its path, and everything else keeps its place")
    func removingAChipDropsOnlyItsPath() {
        // What ChainedTaskSubmissionService stores; a queued task can be moved back to draft.
        // A path inside prose is still prose.
        let chained = "Previous task output (Summarize Q3 sales):\nRevenue grew 12%.\nDetails in /Users/me/q3.xlsx."
        let draft = AgentTask(title: "Follow up on Q3", goal: "Follow up on Q3")
        draft.inputs = ["/Users/me/q2.xlsx", chained, "/Users/me/q3.xlsx"]

        var composer = DraftComposer()
        composer.reopen(draft)
        #expect(composer.attachedFiles == ["/Users/me/q2.xlsx", "/Users/me/q3.xlsx"])

        composer.attachedFiles.removeAll { $0 == "/Users/me/q2.xlsx" }
        composer.attachedFiles.append("/Users/me/q4.xlsx")
        composer.save(into: draft)
        #expect(draft.inputs == [chained, "/Users/me/q3.xlsx", "/Users/me/q4.xlsx"])
    }

    @Test("chips follow the existing-task composer's rule and key on the stored spelling")
    func chipsFollowTheExistingTaskComposersRule() {
        // Surrounding whitespace comes from prompt-projected paths.
        let padded = "  /Users/me/notes.md\n"
        let inputs = [padded, "~/notes.md", "notes.md", "/Users/me/a.txt", "/Users/me/a.txt"]

        // One chip per path, because chips are identified by their path.
        #expect(ComposerAttachments.paths(in: inputs) == [padded, "/Users/me/a.txt"])
        #expect(ComposerAttachments.displayName(for: padded) == "notes.md")
        // Saving what was just loaded changes nothing: not the padding, not the duplicate.
        #expect(ComposerAttachments.inputs(inputs, replacingPathsWith: ComposerAttachments.paths(in: inputs)) == inputs)
    }

    /// `ChatPanelView` can't be hosted in the test binary, so this pins the calls
    /// that `DraftComposer` stands in for.
    @Test("the draft composer restores its chips and writes them back wherever it acts on the draft")
    func draftComposerWiring() throws {
        let chat = try sourceFile("Astra/Views/ChatPanelView.swift")

        // Ahead of the early return, so a draft rebuilt from its task events gets its chips too.
        let load = try body(of: "loadDraftMessages", in: chat)
        let restore = try #require(load.range(of: "attachedFiles = ComposerAttachments.paths(in: task.inputs)"))
        let firstReturn = try #require(load.range(of: #"\breturn\b"#, options: .regularExpression))
        #expect(restore.lowerBound < firstReturn.lowerBound)

        let save = try body(of: "saveDraft", in: chat)
        let existingDraft = try #require(save.range(of: "if let draft = draftTask {"))
        let newDraft = try #require(save[existingDraft.upperBound...].range(of: "} else {"))
        #expect(save[existingDraft.upperBound..<newDraft.lowerBound].contains(
            "draft.inputs = ComposerAttachments.inputs(draft.inputs, replacingPathsWith: attachedFiles)"
        ))

        // Neither plan path runs saveDraft() on an existing draft. Approving also hands
        // the draft to a fresh composer that reloads its chips from it.
        let writeBack = "task.inputs = ComposerAttachments.inputs(task.inputs, replacingPathsWith: attachedFiles)"
        let approve = try body(of: "approvePendingPlan", in: chat)
        #expect(approve.contains(writeBack))

        // Not on a read-only task, and before submitPlan derives resource claims from inputs.
        let run = try body(of: "runApprovedPlan", in: chat)
        let sync = try #require(run.range(of: writeBack))
        let readOnlyGuard = try #require(run.range(of: "TaskForkPolicyService.readOnlyReason(for: task)"))
        let submit = try #require(run.range(of: "ExecutionRequestSubmissionService.submitPlan("))
        #expect(readOnlyGuard.lowerBound < sync.lowerBound)
        #expect(sync.lowerBound < submit.lowerBound)

        // Both composers draw a chip the same way.
        #expect(chat.contains("Text(ComposerAttachments.displayName(for: file))"))
        let chips = try sourceFile("Astra/Views/Components/ComposerInputChipsView.swift")
        #expect(chips.contains("ComposerAttachments.paths(in: task.inputs)"))
        #expect(chips.contains("ComposerAttachments.displayName(for: path)"))
    }

    /// Start Over deletes the draft, so the chips restored from it have to go
    /// with it; left behind, the next `quickRun()` or `saveDraft()` files them
    /// under a task they never belonged to.
    @Test("starting over drops the chips restored from the deleted draft")
    func startingOverDropsRestoredChips() throws {
        let chat = try sourceFile("Astra/Views/ChatPanelView.swift")
        let label = try #require(chat.range(of: "Text(\"Start Over\")"))
        let button = try #require(chat[..<label.lowerBound].range(of: "Button {", options: .backwards))
        let startOver = chat[button.upperBound..<label.lowerBound]
        #expect(startOver.contains("modelContext.delete(draft)"))
        #expect(startOver.contains("attachedFiles = []"))
    }

    private func body(of function: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "func \(function)("))
        let end = try #require(source[start.upperBound...].range(of: "\n    }\n"))
        return source[start.upperBound..<end.lowerBound]
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
