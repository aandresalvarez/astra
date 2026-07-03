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
/// streaming, or scheduling: the process-group spawn attribute and the
/// self-guarded group-kill primitive. Timeout policy, grace periods, and
/// concurrency style (async `Task.sleep` vs `DispatchQueue.asyncAfter` vs
/// synchronous `usleep`) intentionally stay with each caller — they differ
/// across the three stacks and folding them together would be a behavior
/// change, not a dedup.
public enum ProcessGroupSpawn {
    /// Configures `attr` so `posix_spawn` places the child in a new process
    /// group headed by itself (`setpgid(child, 0)` semantics via
    /// `posix_spawnattr_setpgroup(attr, 0)`). Callers still perform the
    /// `posix_spawn` call themselves with their own file actions.
    ///
    /// Returns `false` if either attribute call fails; the caller should
    /// treat that as a launch failure and must not proceed to `posix_spawn`
    /// without process-group isolation.
    @discardableResult
    public static func configureNewProcessGroup(_ attr: inout posix_spawnattr_t?) -> Bool {
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attr, flags) == 0,
              posix_spawnattr_setpgroup(&attr, 0) == 0 else {
            return false
        }
        return true
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
