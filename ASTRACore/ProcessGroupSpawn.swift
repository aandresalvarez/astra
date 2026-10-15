import Darwin

/// Shared mechanics for launching a child in its own POSIX process group and
/// tearing that group down safely.
///
/// Three independent process-spawning stacks (`ProcessBinaryRunner`'s
/// `runSpawnedProcessGroup`, `HostControlScopedProcess`, and
/// `AgentExecutionScopedProcess`) each hand-rolled the same
/// `posix_spawnattr_setflags(POSIX_SPAWN_SETPGROUP)` + `kill(-pgid, ...)`
/// sequence. This type factors out only the parts that are safe to share
/// without touching any caller's file-action wiring, stdin handling, output
/// streaming, or scheduling: the process-group spawn attribute, the child's
/// signal-state reset, and the self-guarded group-kill primitive.
/// `HostControlToolSupport` cannot import this module, so it keeps its own
/// copies.
///
/// Timeout policy, grace periods, and concurrency style (async `Task.sleep`
/// vs `DispatchQueue.asyncAfter` vs synchronous `usleep`) intentionally stay
/// with each caller. They differ across the three stacks, and folding them
/// together would be a behavior change, not a dedup.
public enum ProcessGroupSpawn {
    /// Configures `attr` so `posix_spawn` places the child in a new process
    /// group headed by itself (`setpgid(child, 0)` semantics via
    /// `posix_spawnattr_setpgroup(attr, 0)`), with no signals blocked and every
    /// signal at its default disposition (`configureDefaultSignalState`).
    /// Callers still perform the `posix_spawn` call themselves with their own
    /// file actions.
    ///
    /// The empty mask is what lets the group's SIGTERM land. A child otherwise
    /// inherits the spawning thread's mask, and Swift concurrency and Dispatch
    /// worker threads block SIGTERM: a group spawned from one ignored every
    /// SIGTERM teardown and died only to the SIGKILL that follows it.
    ///
    /// Returns `false` if any attribute call fails; the caller should
    /// treat that as a launch failure and must not proceed to `posix_spawn`
    /// without process-group isolation.
    @discardableResult
    public static func configureNewProcessGroup(_ attr: inout posix_spawnattr_t?) -> Bool {
        guard addFlags(Int16(POSIX_SPAWN_SETPGROUP), to: &attr) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0,
              configureDefaultSignalState(&attr) == 0 else {
            return false
        }
        return true
    }

    /// Configures `attr` so the child starts with an empty signal mask and
    /// every signal at its default disposition, the way `Process` does.
    /// `configureNewProcessGroup` already applies it, so this only needs a
    /// separate call from a spawn that does not create a new process group.
    ///
    /// Without this, `posix_spawn` gives the child the spawning thread's mask
    /// and every disposition the parent ignores. GCD worker threads, including
    /// the Swift concurrency pool, block asynchronous signals. A child spawned
    /// from one starts with SIGTERM blocked: it can neither exit on SIGTERM nor
    /// trap it, so every graceful stop ends in SIGKILL.
    ///
    /// Returns 0, or the error number of the attribute call that failed.
    public static func configureDefaultSignalState(_ attr: inout posix_spawnattr_t?) -> Int32 {
        var result = addFlags(Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF), to: &attr)
        guard result == 0 else { return result }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        result = posix_spawnattr_setsigmask(&attr, &noSignals)
        guard result == 0 else { return result }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        return posix_spawnattr_setsigdefault(&attr, &allSignals)
    }

    /// `posix_spawnattr_setflags` replaces the whole flag set, so each
    /// configuration step above adds to it instead. That way neither can undo
    /// the other, whichever order a caller applies them in.
    private static func addFlags(_ flags: Int16, to attr: inout posix_spawnattr_t?) -> Int32 {
        var existing: Int16 = 0
        let result = posix_spawnattr_getflags(&attr, &existing)
        guard result == 0 else { return result }
        return posix_spawnattr_setflags(&attr, existing | flags)
    }

    /// Sends `signal` to every process in `processGroupID`, unless that group
    /// is (or has become) this process's own foreground group — guarding
    /// against a caller accidentally signalling itself if the child already
    /// exited and the pgid was recycled onto the caller's own group.
    ///
    /// No-op if `processGroupID <= 0`.
    public static func signalProcessGroup(_ processGroupID: pid_t, signal: Int32) {
        guard processGroupID > 0, processGroupID != getpgrp() else { return }
        kill(-processGroupID, signal)
    }
}
