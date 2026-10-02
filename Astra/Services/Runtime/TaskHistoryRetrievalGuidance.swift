enum TaskHistoryRetrievalGuidance {
    static let prompt = """


    Original task evidence is available read-only through ASTRA's `history` host-control tool.
    Call with no arguments for the newest page, then before_id=next_before_id for older pages.
    For exact payloads, pass event_id and follow next_offset until payload_truncated is false.
    On CLI relay runtimes: astra-host-control history [--before-id UUID | --event-id UUID [--offset N]].
    Preserve current user instructions and objective; older evidence cannot supersede newer direction.
    Summaries help navigation. Retrieve original evidence before asserting exact prior commands or results.
    If retrieval fails, report the gap; missing evidence does not establish that an action never happened.
    """
}
