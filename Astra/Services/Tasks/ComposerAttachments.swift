import Foundation

/// The path entries of a task's `inputs`, which the composers show and edit as
/// attachment chips.
///
/// `inputs` also carries prose that no composer shows: a chained task's
/// "Previous task output" and a Workspace App's provenance lines. That prose
/// belongs to the task, not the chips — as a chip it is a garbage file name,
/// and `ChatPanelView` would tell the planner the user dragged it in. So the
/// new-task composer restores only the paths into `attachedFiles`, and every
/// write of its chips back into a draft (`saveDraft()`, and the plan paths
/// that act on the draft without one) replaces only the path entries.
/// Reopening a draft and saving it unchanged stores exactly what it loaded.
enum ComposerAttachments {
    /// Whether `input` is shown as a chip. A path may carry prompt-projection
    /// whitespace; `~/` and relative strings stay prose, as they always have in
    /// `ComposerInputChipsView`.
    static func isAttachment(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    /// The chips for `inputs`, in stored order and stored spelling. A path
    /// stored twice is one chip, because chips are identified by their path.
    static func paths(in inputs: [String]) -> [String] {
        var seen = Set<String>()
        return inputs.filter { isAttachment($0) && seen.insert($0).inserted }
    }

    /// `inputs` with its path entries replaced by `attachments`. Prose and
    /// still-attached paths keep their place, a removed chip's path is dropped,
    /// and a newly attached one is appended.
    static func inputs(_ inputs: [String], replacingPathsWith attachments: [String]) -> [String] {
        let attached = Set(attachments)
        var merged = inputs.filter { !isAttachment($0) || attached.contains($0) }
        var present = Set(merged)
        for attachment in attachments where present.insert(attachment).inserted {
            merged.append(attachment)
        }
        return merged
    }

    static func displayName(for path: String) -> String {
        URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
    }
}
