import Foundation
import os

/// The innermost instrumented scope the main thread is currently inside.
///
/// `MainThreadStallMonitor` can say that the main thread stopped servicing its
/// run loop, and how much memory it was holding while it did. It cannot say
/// what it stopped *inside*, so every stall investigated so far has cost a
/// `sample` against a stripped binary plus a symbolication pass — run against a
/// process the user usually just wants to kill, and often gone by the time
/// anyone reads the log.
///
/// The watchdog cannot ask the main thread where it is: it runs on a background
/// queue precisely because the main thread is unreachable. So the main thread
/// publishes where it is *on the way in*, and the watchdog reads whatever was
/// published last.
///
/// That inverts the limitation the stall monitor documents. Telemetry that only
/// reports scopes it leaves is blind to the scope that never ends; a marker
/// written at entry is only still standing *because* its scope never returned,
/// which makes the unfinished scope the one thing the watchdog can name.
enum MainThreadPhase {
    /// Deep enough for the nesting the instrumented paths actually reach — a
    /// transcript render inside a snapshot build inside a history page read is
    /// three — and shallow enough that the storage is a fixed allocation made
    /// once, so a push never has to grow an array while holding the lock.
    static let maximumDepth = 16

    /// What the main thread was inside when the watchdog looked.
    enum Snapshot: Equatable {
        /// Running, but not inside any instrumented scope. Worth distinguishing
        /// from `unavailable`: it says the stall is somewhere this app does not
        /// measure — SwiftUI or AppKit internals — which is a different search
        /// than a stall in a scope ASTRA owns.
        case idle
        case inside(label: String, depth: Int)
        /// The lock was held when the watchdog tried. Reported rather than
        /// waited on; see `snapshot()`.
        case unavailable
        /// Read cleanly, but the stack moved before the line was written — so
        /// the main thread is running again and the label may name a scope that
        /// has already returned. Its own token rather than the label, because a
        /// phase that cannot be trusted is the one thing this field must never
        /// assert. See `MainThreadStallMonitor.report`.
        case stale

        /// Fields for the stall report. The key is `phase` rather than `scope`
        /// to match how the existing reports read (`stalled_s`, `footprint_mb`).
        var telemetryFields: [String: String] {
            switch self {
            case .idle:
                return ["phase": "none"]
            case let .inside(label, depth):
                return ["phase": label, "phase_depth": String(depth)]
            case .unavailable:
                return ["phase": "unavailable"]
            case .stale:
                return ["phase": "stale"]
            }
        }
    }

    /// A phase plus the stack revision it was read at, so a reader that acts on
    /// it later can tell whether it still describes the same moment.
    struct Reading: Equatable {
        let snapshot: Snapshot
        let generation: UInt64
    }

    private struct Storage {
        var labels: [String?]
        var depth: Int
        /// Bumped by every push and pop.
        ///
        /// The watchdog reads the phase from a background queue while the main
        /// thread is *presumed* wedged, and nothing makes that presumption
        /// atomic: `pop()` takes only this lock and never waits on the
        /// monitor's, so a thread that wakes at the wrong moment can unwind the
        /// stalled scope between the read and the line being written. A counter
        /// costs one increment on a path that runs per instrumented scope —
        /// cheaper than reading a clock — and lets that reader detect the
        /// change instead of silently reporting a scope that already returned.
        var generation: UInt64
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: Storage(
            labels: Array(repeating: nil, count: MainThreadPhase.maximumDepth),
            depth: 0,
            generation: 0
        )
    )

    /// Records that the main thread has entered `label`. Returns whether a
    /// matching `pop()` is owed, so a caller can pair them with `defer` without
    /// having to repeat the main-thread and depth conditions.
    ///
    /// Off-main callers are ignored on purpose. Most instrumented scopes run on
    /// both, and a background scope publishing here would name a phase the main
    /// thread was never in — a stall report that points at the wrong code is
    /// worse than one that admits it does not know.
    static func push(_ label: String) -> Bool {
        guard Thread.isMainThread else { return false }
        return state.withLock { storage in
            guard storage.depth < maximumDepth else { return false }
            storage.labels[storage.depth] = label
            storage.depth += 1
            storage.generation &+= 1
            return true
        }
    }

    static func pop() {
        guard Thread.isMainThread else { return }
        state.withLock { storage in
            guard storage.depth > 0 else { return }
            storage.depth -= 1
            storage.labels[storage.depth] = nil
            storage.generation &+= 1
        }
    }

    /// The innermost scope currently open, read without ever blocking.
    ///
    /// `withLockIfAvailable` is a `trylock`: the one thread this could contend
    /// with is the thread that is, by hypothesis, wedged. Waiting on it would
    /// park the watchdog inside the stall it exists to report — the second
    /// failure mode `MainThreadStallMonitor` warns about — so an unavailable
    /// lock is reported as a fact instead.
    static func snapshot() -> Snapshot {
        reading().snapshot
    }

    /// The innermost scope plus the revision it was read at.
    ///
    /// A caller that writes the result somewhere later — the stall report does,
    /// after a `task_info` syscall — should pass the generation back to
    /// `hasMutated(since:)` first, and treat a change as "the main thread woke
    /// up, this label is no longer about the stall".
    static func reading() -> Reading {
        let result = state.withLockIfAvailable { storage -> Reading in
            guard storage.depth > 0, let label = storage.labels[storage.depth - 1] else {
                return Reading(snapshot: .idle, generation: storage.generation)
            }
            return Reading(
                snapshot: .inside(label: label, depth: storage.depth),
                generation: storage.generation
            )
        }
        return result ?? Reading(snapshot: .unavailable, generation: 0)
    }

    /// Whether the stack has been pushed or popped since `generation`.
    ///
    /// An unavailable lock counts as mutated: the only thread that can hold it
    /// is one actively pushing or popping, which is the very thing this asks
    /// about.
    static func hasMutated(since generation: UInt64) -> Bool {
        let unchanged = state.withLockIfAvailable { storage in
            storage.generation == generation
        }
        return unchanged != true
    }

    /// Runs `work` with `label` published as the current phase.
    @discardableResult
    static func tracking<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let pushed = push(label)
        defer { if pushed { pop() } }
        return try work()
    }

    /// Runs `body` with the lock held, so a test can prove `snapshot()` reports
    /// contention instead of waiting for it. Safe to call `snapshot()` inside:
    /// `os_unfair_lock` is not recursive, and a `trylock` from the thread that
    /// already owns it fails rather than deadlocking — which is the same answer
    /// the watchdog would get from a main thread wedged mid-push.
    static func withLockHeldForTesting<T>(_ body: () -> T) -> T {
        state.withLock { _ in body() }
    }

    /// Drops every recorded phase. Tests only: the stack is process-global, and
    /// a test that leaves one pushed would name its own scope in an unrelated
    /// suite's stall report.
    static func resetForTesting() {
        state.withLock { storage in
            for index in storage.labels.indices { storage.labels[index] = nil }
            storage.depth = 0
            storage.generation &+= 1
        }
    }
}
