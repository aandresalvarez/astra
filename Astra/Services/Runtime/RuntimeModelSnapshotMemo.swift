import Foundation
import ASTRACore

/// A provider's model snapshot decoded once, with its details indexed by model
/// id so per-model lookups are O(1).
struct DecodedRuntimeModelSnapshot: Sendable {
    let snapshot: RuntimeModelAvailabilitySnapshot?
    let detailsByValue: [String: RuntimeModelDetail]

    init(snapshot: RuntimeModelAvailabilitySnapshot?) {
        self.snapshot = snapshot
        var details: [String: RuntimeModelDetail] = [:]
        // First entry wins, matching the linear `first { $0.value == id }`
        // lookup this index replaces.
        for detail in snapshot?.details ?? [] where details[detail.value] == nil {
            details[detail.value] = detail
        }
        detailsByValue = details
    }
}

/// Remembers the last decoded snapshot per runtime.
///
/// Every display-name or description lookup used to re-decode the provider's
/// whole JSON: the model selector's ~250 Cursor rows cost ~330 ms (two lookups
/// per row, each decoding all 246 entries), measured by
/// `model_selector_rows_build`.
///
/// Process-wide on purpose, and safe to share: decoding is a pure function of
/// `(runtime, raw)` and an entry is reused only when the raw string is
/// identical to the one it was decoded from. There is no configuration key and
/// no injected dependency, so two callers (or two tests) can never be served
/// each other's answer; a changed cache simply re-decodes.
final class RuntimeModelSnapshotMemo: @unchecked Sendable {
    static let shared = RuntimeModelSnapshotMemo()

    private struct Entry {
        let raw: String
        let decoded: DecodedRuntimeModelSnapshot
    }

    private let lock = NSLock()
    private var entries: [AgentRuntimeID: Entry] = [:]

    func decoded(
        raw: String,
        runtime: AgentRuntimeID,
        decode: (String) -> RuntimeModelAvailabilitySnapshot?
    ) -> DecodedRuntimeModelSnapshot {
        lock.lock()
        let hit = entries[runtime].flatMap { $0.raw == raw ? $0.decoded : nil }
        lock.unlock()
        if let hit { return hit }

        let decoded = DecodedRuntimeModelSnapshot(snapshot: decode(raw))
        lock.lock()
        entries[runtime] = Entry(raw: raw, decoded: decoded)
        lock.unlock()
        return decoded
    }
}
