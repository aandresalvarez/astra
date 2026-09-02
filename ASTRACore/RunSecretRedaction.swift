import Foundation
import os

/// Host-side redaction of a run's live credential values.
///
/// The out-of-process broker (`Tools/HostControlToolSupport`) has always
/// redacted secrets out of the payloads it hands back, but it only sees what
/// passes through *it*. Anything the agent obtained another way — an env var it
/// echoed, a `curl` it ran itself, an error body a service reflected back —
/// reached the transcript unredacted, and that is how a live Atlassian token
/// ended up persisted in three `TaskEvent` payloads. So the same rule now runs
/// at the host's own persistence boundary, where every payload passes
/// regardless of origin.
///
/// The broker keeps its own copy of this logic rather than importing this file:
/// it is a separate executable whose only dependency is `MCPServerKit`, and
/// giving it `ASTRACore` would pull the whole app model graph into the agent's
/// address space — the exact coupling the broker exists to avoid.
public enum RunSecretRedaction {
    public static let marker = "[redacted]"

    /// Shortest value treated as a secret. Below this, replacement does more
    /// damage than good: a two-character "token" appears everywhere in prose.
    public static let minimumSecretLength = 4

    /// Shortest *partial* match redacted. A secret that was split across two
    /// streamed chunks, or truncated by an output cap, leaves a fragment behind
    /// that exact-value replacement cannot see. Eight bytes is long enough that
    /// ordinary text does not collide with the head of a real credential.
    public static let minimumFragmentLength = 8

    /// Every environment-name pattern that can put a value in the Keychain.
    ///
    /// The single owner of that list. It used to be copied into `Skill`, into
    /// the connectors UI, and — narrower — into the predicate below, and the
    /// narrowing is what left `SSH_PRIVATE_KEY` and `CLIENT_AUTH` readable: a
    /// name matching bare `KEY` or `AUTH` was loaded from the Keychain and
    /// projected into the agent environment, but never redacted from a
    /// transcript. Anything storage treats as a secret has to be redactable,
    /// so the two predicates now read from one list instead of agreeing by
    /// hand.
    public static let keychainBackedKeyPatterns = [
        "KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH"
    ]

    /// The names that match a pattern above and still are not credentials.
    ///
    /// A REDCap or Jira `PROJECT_KEY` is a short project name that runs
    /// through ordinary prose, and a `KEY_ID` names the public half of a pair.
    /// Redacting those shreds a transcript without protecting anything, which
    /// is the failure mode in the other direction. This is the one place the
    /// storage and redaction predicates are allowed to disagree, so the
    /// exceptions are enumerated here rather than inferred from shape.
    ///
    /// `SSH_AUTH_SOCK` is here because the redaction set is now built from the
    /// environment ASTRA was *launched* with, not just from the connector
    /// overlay, and macOS puts an agent socket path in that name on every
    /// login session. Its value is `/private/tmp/com.apple.launchd.…`, and
    /// fragment redaction matches on eight bytes, so registering it would
    /// replace `/private` everywhere it appears — a transcript full of
    /// `[redacted]` file paths, protecting a socket path that is not a secret.
    public static let nonCredentialKeyNames = ["PROJECT_KEY", "KEY_ID", "SSH_AUTH_SOCK"]

    /// Whether an exception above names *this* variable, rather than merely
    /// appearing somewhere inside its name.
    ///
    /// The distinction is the whole safety of the exception list. Matched as a
    /// bare substring, `PROJECT_KEY` also swallowed `PROJECT_KEY_TOKEN` and
    /// `KEY_ID` swallowed `KEY_ID_SECRET` — names that `Skill.isSecretEnvironmentKey`
    /// (which has no exception list) stores in the Keychain and projects into
    /// the agent environment. The value went out and never came back through
    /// either launch-time redaction or the startup purge, so an agent echoing
    /// it persisted it in the clear.
    ///
    /// So an exception has to own the *end* of the name: `PROJECT_KEY` and
    /// `JIRA_PROJECT_KEY` are the project name the exception is about, while
    /// anything with a further `_TOKEN`, `_SECRET`, or `_PASSWORD` after it is a
    /// credential that happens to be scoped by one. Prefix and infix matches are
    /// deliberately not accepted: a suffix is what changes what a name *is*.
    static func isNonCredentialKeyName(_ upper: String) -> Bool {
        nonCredentialKeyNames.contains { exception in
            upper == exception || upper.hasSuffix("_" + exception)
        }
    }

    /// Whether an environment variable's *name* says it holds a credential.
    ///
    /// Keyed on the name rather than the value because the projection also
    /// carries base URLs, project IDs, and file paths.
    public static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard !isNonCredentialKeyName(upper) else { return false }
        return keychainBackedKeyPatterns.contains { upper.contains($0) }
    }

    /// The credential values in a resolved launch environment.
    public static func secretValues(in environment: [String: String]) -> [String] {
        var values: [String] = []
        for (key, value) in environment where isSecretKey(key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumSecretLength else { continue }
            values.append(trimmed)
        }
        return Array(Set(values))
    }

    /// Replaces every occurrence of every secret, longest first so a secret
    /// that contains another does not leave the shorter one's suffix behind.
    public static func redact(_ text: String, secrets: [String]) -> String {
        guard !text.isEmpty, !secrets.isEmpty else { return text }
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= minimumSecretLength {
            guard result.contains(secret) else { continue }
            result = result.replacingOccurrences(of: secret, with: marker)
        }
        return redactFragments(result, secrets: secrets)
    }

    /// Redacts leading fragments of a secret — what a chunk split or an output
    /// cap leaves behind after exact replacement has run.
    static func redactFragments(_ text: String, secrets: [String]) -> String {
        let source = Array(text.utf8)
        guard !source.isEmpty else { return text }
        let needles = secrets
            .map { Array($0.utf8) }
            .filter { $0.count > minimumFragmentLength }
        guard !needles.isEmpty else { return text }

        var ranges: [Range<Int>] = []
        for needle in needles {
            var index = 0
            while index + minimumFragmentLength <= source.count {
                guard source[index] == needle[0] else {
                    index += 1
                    continue
                }
                var length = 0
                let limit = min(needle.count, source.count - index)
                while length < limit, source[index + length] == needle[length] {
                    length += 1
                }
                guard length >= minimumFragmentLength else {
                    index += 1
                    continue
                }
                ranges.append(index..<(index + length))
                index += length
            }
        }
        guard !ranges.isEmpty else { return text }

        let merged = ranges
            .sorted { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }
            .reduce(into: [Range<Int>]()) { merged, range in
                guard let last = merged.last else {
                    merged.append(range)
                    return
                }
                if range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }

        let replacement = Array(marker.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var cursor = 0
        for range in merged {
            output.append(contentsOf: source[cursor..<range.lowerBound])
            output.append(contentsOf: replacement)
            cursor = range.upperBound
        }
        output.append(contentsOf: source[cursor...])
        return String(decoding: output, as: UTF8.self)
    }
}

/// The live secret set for each task, cached so the redaction pass does not
/// rebuild a full capability resolution per event.
///
/// Rebuilding per event is what made a funnel-wide pass unaffordable before:
/// `AgentSensitiveRedactions.values(for:)` resolves the task's whole capability
/// inventory, which is fine once per launch and ruinous once per streamed
/// chunk. The set is registered when a run's environment is built — after
/// brokered connectors have been stripped out of it, so a value the agent never
/// receives is not needlessly scrubbed from its transcript.
public enum RunSecretRedactionScope {
    /// Tasks retained after their run ends. Redaction has to outlive the run
    /// itself — handoffs, checkpoints, and post-run summaries all write
    /// payloads — and a task's set is replaced wholesale on its next launch,
    /// so this bounds memory without a lifecycle callback that could be missed.
    ///
    /// It is a ceiling on *finished* runs only. See `beginRun(taskID:)`.
    public static let retainedTaskLimit = 16

    /// Distinct values retained per task. Registration accumulates rather than
    /// replaces (see `register`), so this is what stops a task that relaunches
    /// a hundred times with rotating credentials from growing without bound.
    public static let retainedSecretsPerTask = 64

    private struct State {
        /// Most-recently-registered first within each task, so the cap drops
        /// the oldest values.
        var secretsByTaskID: [UUID: [String]] = [:]
        /// Least-recently-*used* first, where a use is a registration or a
        /// redaction pass. Registration order alone was wrong: a long task
        /// registers once at launch and then redacts for hours, so sixteen
        /// short tasks starting after it would evict the live one and every
        /// credential it echoed from then on would persist in the clear.
        ///
        /// Reading keeps a task alive, but only while it is reading: a run that
        /// is silent for long enough is indistinguishable from a finished one
        /// here. That is what `activeRunDepthByTaskID` is for.
        var order: [UUID] = []
        /// Tasks with a live agent process, by nesting depth. Never evicted.
        ///
        /// A count rather than a set because one task can have overlapping
        /// launches — a phase that starts before the previous one's reaper has
        /// finished — and the inner one ending must not unpin the outer.
        var activeRunDepthByTaskID: [UUID: Int] = [:]
        /// Non-empty iff at least one task has secrets, so the common case
        /// (no connectors, or none with credentials) costs one bool read.
        var isEmpty: Bool { secretsByTaskID.isEmpty }

        /// Moves `taskID` to the most-recently-used end. Called on every read,
        /// so it is deliberately a no-op when it is already there — `order`
        /// holds at most `retainedTaskLimit` entries and the streaming path
        /// hits this on every chunk.
        mutating func touch(_ taskID: UUID) {
            guard order.last != taskID else { return }
            order.removeAll { $0 == taskID }
            order.append(taskID)
        }

        /// Reads a task's secrets and marks it used in one lock acquisition.
        ///
        /// Returns before touching when the scope is missing, which is worth
        /// saying out loud: a read cannot resurrect an evicted task, so
        /// read-based LRU protects a task that is *writing* and nothing else.
        /// Protecting a task that is merely *running* is `activeRunDepthByTaskID`'s
        /// job, not this one's.
        mutating func use(_ taskID: UUID) -> [String] {
            guard !isEmpty, let secrets = secretsByTaskID[taskID], !secrets.isEmpty else { return [] }
            touch(taskID)
            return secrets
        }

        /// Drops least-recently-used *inactive* scopes down to the limit.
        ///
        /// Stops rather than evicting an active one. `retainedTaskLimit` bounds
        /// scopes kept for tasks that are no longer running; a live process is
        /// bounded by the app's own run concurrency, and each scope is already
        /// capped at `retainedSecretsPerTask` values, so retaining every active
        /// one cannot grow without bound. Evicting one could: the run keeps
        /// producing output, and every line of it after the eviction would be
        /// persisted unredacted.
        mutating func evictInactiveOverflow(limit: Int) {
            while order.count > limit {
                guard let index = order.firstIndex(where: { activeRunDepthByTaskID[$0] == nil }) else { return }
                let evicted = order.remove(at: index)
                secretsByTaskID.removeValue(forKey: evicted)
            }
        }
    }

    private static let storage = OSAllocatedUnfairLock(initialState: State())

    /// Registers secrets an agent run may see.
    ///
    /// Accumulates rather than replaces. The environment is resolved several
    /// times per launch — preflight, the launch itself, the permission summary
    /// — and those resolutions do not all see the same connectors, so a later
    /// narrower one must not be able to shrink the set and unredact a value an
    /// earlier one knew about. A rotated credential lingering in the set costs
    /// nothing: it was a real secret, and redacting it stays correct.
    public static func register(taskID: UUID, secrets: [String]) {
        let usable = secrets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= RunSecretRedaction.minimumSecretLength }
        guard !usable.isEmpty else { return }
        storage.withLock { state in
            var merged = usable
            merged.append(contentsOf: state.secretsByTaskID[taskID] ?? [])
            var seen = Set<String>()
            state.secretsByTaskID[taskID] = merged
                .filter { seen.insert($0).inserted }
                .prefix(retainedSecretsPerTask)
                .map { $0 }
            state.touch(taskID)
            state.evictInactiveOverflow(limit: retainedTaskLimit)
        }
    }

    /// Pins a task's scope for as long as its agent process is alive.
    ///
    /// Eviction is least-recently-*used*, and a scope is only used when its task
    /// writes something. A credential-bearing run that is thinking, waiting on a
    /// tool, or blocked on an approval writes nothing, so sixteen shorter runs
    /// starting after it used to evict it — and because `State.use` returns
    /// before touching when the scope is gone, its next line of output could not
    /// bring it back. It was persisted in the clear, and so was everything after
    /// it.
    ///
    /// Balanced by `endRun(taskID:)`, which does not drop the secrets: redaction
    /// still has to outlive the run for handoffs and post-run summaries. It only
    /// makes the scope evictable again, which is what the LRU was always for.
    public static func beginRun(taskID: UUID) {
        storage.withLock { state in
            state.activeRunDepthByTaskID[taskID, default: 0] += 1
        }
    }

    public static func endRun(taskID: UUID) {
        storage.withLock { state in
            guard let depth = state.activeRunDepthByTaskID[taskID] else { return }
            if depth <= 1 {
                state.activeRunDepthByTaskID.removeValue(forKey: taskID)
            } else {
                state.activeRunDepthByTaskID[taskID] = depth - 1
            }
            // The scope stopped being pinned, so the backlog it was holding open
            // can go now rather than waiting for the next registration.
            state.evictInactiveOverflow(limit: retainedTaskLimit)
        }
    }

    /// Whether a task's scope is currently pinned. Test and diagnostic seam.
    public static func isRunActive(taskID: UUID) -> Bool {
        storage.withLock { $0.activeRunDepthByTaskID[taskID] != nil }
    }

    /// Registers the credential values found in a resolved launch environment.
    public static func register(taskID: UUID, environment: [String: String]) {
        register(taskID: taskID, secrets: RunSecretRedaction.secretValues(in: environment))
    }

    public static func forget(taskID: UUID) {
        storage.withLock { state in
            state.secretsByTaskID.removeValue(forKey: taskID)
            state.order.removeAll { $0 == taskID }
        }
    }

    public static func forgetAll() {
        storage.withLock { $0 = State() }
    }

    public static func secrets(for taskID: UUID) -> [String] {
        storage.withLock { $0.use(taskID) }
    }

    /// The redaction pass itself. Returns `text` untouched — without copying —
    /// when nothing is registered, which is every run that has no credentials
    /// and every test that never launched one.
    public static func redact(_ text: String, taskID: UUID?) -> String {
        guard !text.isEmpty, let taskID else { return text }
        let secrets = storage.withLock { $0.use(taskID) }
        guard !secrets.isEmpty else { return text }
        return RunSecretRedaction.redact(text, secrets: secrets)
    }

    /// Redacts an append across the seam between existing text and the chunk
    /// being added to it.
    ///
    /// Streamed conversation events are coalesced by appending to a payload
    /// already persisted, so a secret can straddle the boundary: neither half
    /// matches on its own. Only the tail of the existing text can participate
    /// in such a match, so the join window is bounded by the longest secret
    /// rather than the payload length — otherwise coalescing a long run would
    /// re-scan the whole transcript on every tick.
    ///
    /// Returns the number of trailing characters of `existing` to drop and the
    /// redacted text to append in their place.
    public static func redactedAppend(
        existing: String,
        addition: String,
        taskID: UUID?
    ) -> (dropFromExisting: Int, append: String) {
        guard !addition.isEmpty, let taskID else { return (0, addition) }
        let secrets = storage.withLock { $0.use(taskID) }
        guard !secrets.isEmpty else { return (0, addition) }

        let window = (secrets.map(\.count).max() ?? 0) - 1
        guard window > 0 else { return (0, RunSecretRedaction.redact(addition, secrets: secrets)) }
        let tail = String(existing.suffix(window))
        let redacted = RunSecretRedaction.redact(tail + addition, secrets: secrets)
        // Nothing straddled the seam: keep the existing text byte-identical and
        // append only what the caller asked for.
        if redacted.hasPrefix(tail) {
            return (0, String(redacted.dropFirst(tail.count)))
        }
        return (tail.count, redacted)
    }
}
