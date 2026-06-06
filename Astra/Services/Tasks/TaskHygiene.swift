import Foundation

/// Cleans up the raw output of the title-generation utility before it is
/// persisted as a task title.
///
/// The CLI utility occasionally emits the generated title twice, concatenated
/// with itself (`"New greetingNew greeting"`). Two separate view layers (the
/// Kanban card and the sidebar row) used to paper over this at render time;
/// sanitising at the *source* means the stored value is clean and every
/// surface benefits without its own dedup pass.
enum TaskTitleSanitizer {
    /// Trim, strip wrapping quotes, and collapse a string that is exactly
    /// itself repeated twice. Returns the cleaned title.
    static func sanitizeGeneratedTitle(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapseDoubled(trimmed)
    }

    /// Collapse `"abcabc"` -> `"abc"` when a string is exactly its first half
    /// repeated. Conservative: requires an even length and either an embedded
    /// space in the half (real titles are multi-word) or a half of at least 6
    /// characters, so genuine reduplications like "bonbon" or "hihi" are left
    /// alone.
    static func collapseDoubled(_ text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty, characters.count.isMultiple(of: 2) else { return text }

        let midpoint = characters.count / 2
        let firstHalf = String(characters[..<midpoint])
        let secondHalf = String(characters[midpoint...])
        guard firstHalf == secondHalf else { return text }

        let isMeaningfulHalf = firstHalf.contains(" ") || firstHalf.count >= 6
        guard isMeaningfulHalf else { return text }

        return firstHalf.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Classifies how much *signal* a conversation carries. A conversation that is
/// just a greeting or an "are you there?" probe carries no task intent and is
/// not worth surfacing as supervisable work.
enum TaskConversationSignal {
    /// A single-message conversation shorter than this (after normalisation) is
    /// low-signal even if it matches no known phrase. Deliberately tiny — it
    /// catches "hi", "yo", "ok", "test" without sweeping up terse-but-real tasks
    /// like "Add tests" or "Fix CI". Anything longer must match a greeting word
    /// or probe phrase to be considered noise.
    static let lowSignalMaxCharacters = 5

    private static let greetingFirstWords: Set<String> = [
        "hi", "hii", "hiii", "hey", "heya", "hello", "helo", "yo", "sup",
        "hiya", "howdy", "hola", "greetings"
    ]

    /// Phrases that, on their own, are an opening pleasantry or a probe of the
    /// assistant's identity/capabilities rather than a task. Matched as a whole
    /// string or as a leading prefix of the (normalised) message.
    private static let probePhrases: [String] = [
        "who are you", "what are you", "what is your name", "whats your name",
        "what can you do", "what do you do", "introduce yourself",
        "identify yourself", "tell me about yourself",
        "how are you", "how is it going", "hows it going", "how are things",
        "are you there", "you there", "anyone there",
        "new conversation", "new session", "new chat", "new thread",
        "good morning", "good afternoon", "good evening",
        "thank you", "thanks", "testing", "test message", "ping"
    ]

    /// Decode the user-authored turns from a draft's JSON message blob.
    /// Returns an empty array when the blob is missing or malformed.
    static func draftUserMessages(fromDraftMessagesJSON json: String) -> [String] {
        struct StoredMessage: Decodable {
            let role: String
            let content: String
        }
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StoredMessage].self, from: data) else {
            return []
        }
        return decoded
            .filter { $0.role.lowercased() == "user" }
            .map { $0.content }
    }

    /// True when the conversation carries no real task intent — a lone greeting
    /// or identity/capability probe. A back-and-forth with two or more
    /// user-authored turns is always treated as substantive.
    static func isLowSignalConversation(goal: String, draftMessagesJSON: String) -> Bool {
        isLowSignalConversation(
            goal: goal,
            userMessages: draftUserMessages(fromDraftMessagesJSON: draftMessagesJSON)
        )
    }

    /// Variant for callers that already hold the decoded user turns (e.g. the
    /// Claude Code session importer).
    static func isLowSignalConversation(goal: String, userMessages: [String]) -> Bool {
        // Two or more user turns means the person engaged with the thread —
        // that's exploration worth keeping regardless of how each turn reads.
        if userMessages.count >= 2 { return false }

        let source = userMessages.first ?? goal
        let normalized = normalize(source)
        if normalized.isEmpty { return true }
        if normalized.count < lowSignalMaxCharacters { return true }
        return isGreetingOrProbe(normalized)
    }

    /// Interrogatives that, in a short message aimed at "you", signal an
    /// identity/capability probe rather than a task.
    private static let probeInterrogatives: Set<String> = ["who", "what", "how", "are"]

    private static func isGreetingOrProbe(_ normalized: String) -> Bool {
        if probePhrases.contains(where: { normalized == $0 || normalized.hasPrefix($0) }) {
            return true
        }
        let words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }

        // Opening greeting: "hi", "hey there", "hello world".
        if words.count <= 4, greetingFirstWords.contains(first) {
            return true
        }

        // Short interrogative aimed at the assistant — "who are you",
        // "what can you do", and typo variants like "who a re you" that exact
        // phrase matching would miss. Bounded to short messages containing a
        // "you"/"your" reference so real how-to questions ("how do I run the
        // tests") are left alone.
        if words.count <= 5,
           probeInterrogatives.contains(first),
           words.contains("you") || words.contains("your") {
            return true
        }
        return false
    }

    /// Lowercase, drop punctuation, and collapse runs of whitespace so phrase
    /// matching is resilient to "Hello!!", "  who   are you? ", etc.
    private static func normalize(_ text: String) -> String {
        let stripped = text.unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
                return " "
            }
        return String(stripped)
            .lowercased()
            .split(separator: " ")
            .joined(separator: " ")
    }
}

/// The board invariant in code: a card is *delegated work*. A draft is the chat
/// you're still shaping into a task — in-composition plumbing, not yet work — so
/// it never appears on the board. These predicates are the single source of
/// truth shared by the board's view filter (hide) and the startup maintenance
/// pass (prune), so the two can never drift apart.
enum TaskHygiene {
    /// The board shows delegated work only. A draft is in-composition state — the
    /// task is born on the board the moment it's queued/run — so every draft is
    /// hidden. (`TaskConversationSignal` still gates which *imported sessions*
    /// are worth surfacing; that's a separate, content-based question.)
    static func isHiddenFromBoard(_ task: AgentTask) -> Bool {
        task.status == .draft
    }

    /// An abandoned draft — never run and not pinned — is safe to delete once it
    /// has gone stale (default 24h since last touch), so a draft being actively
    /// composed isn't pulled out from under the user. With drafts off the board
    /// there's no resume entry point, so a stale draft is pure dead weight.
    static func isPrunableAbandonedDraft(
        _ task: AgentTask,
        olderThan staleInterval: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) -> Bool {
        guard task.status == .draft else { return false }
        guard !task.isPinned else { return false }
        guard task.runs.isEmpty else { return false }
        return now.timeIntervalSince(task.updatedAt) >= staleInterval
    }
}
