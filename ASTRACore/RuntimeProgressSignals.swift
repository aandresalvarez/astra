import Foundation

/// Cross-runtime vocabulary for deciding whether a provider is still working.
///
/// The watchdog used to answer that question purely from `ParsedEvent`'s shape,
/// which made it a whitelist over whatever each parser happened to recognise.
/// When a provider streams work through a frame the parser only half-decodes,
/// the run looks idle while it is in fact busy, and the run gets killed. This
/// type holds the two signals that make the answer parser-independent:
///
/// - `isProgressBearingControl` names the control frames that carry real work
///   even though they never become conversation text.
/// - `semanticProgressByteThreshold` lets raw stream volume stand in for
///   progress when no recognised event is arriving at all.
public enum RuntimeProgressSignals {
    /// Control frames that represent generation or tool work in flight.
    ///
    /// Every entry is a frame that a provider emits *while producing output* —
    /// streaming a tool call's JSON arguments, or streaming a running tool's
    /// partial stdout. Classifying these as mere liveness is what let a run be
    /// killed in the middle of writing its deliverable.
    public static let progressBearingControlTypes: Set<String> = [
        // Claude Code: `content_block_delta` carrying `input_json_delta`.
        // One large Write arrives as thousands of these and nothing else.
        "stream_event.tool_input_delta",
        // Copilot CLI: one tool call's arguments stream as many deltas before
        // the authoritative `tool.execution_start` frame arrives.
        "assistant.tool_call_delta",
        // Copilot CLI: live stdout from a tool that is still running. This is
        // the most direct evidence of work there is.
        "tool.execution_partial_result",
        "tool.execution_progress"
    ]

    public static func isProgressBearingControl(_ type: String) -> Bool {
        progressBearingControlTypes.contains(type)
    }

    /// Stream growth that counts as semantic progress on its own.
    ///
    /// This is the backstop for frames no parser recognises yet. It is
    /// deliberately volume-based rather than shape-based: a provider that has
    /// pushed this many bytes since the last recognised progress event is
    /// observably doing something, whatever the bytes decode to.
    ///
    /// Sized against a real stalled run: ~1 MB of tool-input deltas over 300
    /// seconds, roughly 3.3 KB/s. At 16 KiB the clock refreshes every ~5s while
    /// a large write streams, and a genuinely wedged provider still trips the
    /// window because it emits nothing at all.
    public static let semanticProgressByteThreshold = 16 * 1024

    /// How long a run may keep the provider alive, regardless of how busy it
    /// looks. Silence detection used to be ASTRA's de-facto spend limit; once
    /// stream volume can hold that watchdog off indefinitely, the bound has to
    /// be something the silence detector cannot launder. Wall clock is that
    /// bound, and it is the resource a user actually feels.
    public static let defaultMaxRunSeconds: TimeInterval = 4 * 3600

    /// Token ceiling applied when a task carries no explicit budget.
    ///
    /// Previously an unset budget meant `Int.max` — literally unbounded. This
    /// is set above the worst run observed in production (17.3M tokens on a
    /// single task) so nothing that completes today starts failing, while still
    /// being a finite number that a runaway loop will reach.
    public static let defaultTokenBudget = 25_000_000
}
