import Foundation

/// Wraps a host-control command with a process-group watchdog.
///
/// macOS does not provide Linux's `PR_SET_PDEATHSIG`. Instead, the host keeps
/// the write end of a private pipe open and the watchdog blocks on its read
/// end. Kernel EOF is therefore an authoritative parent-death signal even
/// when the host is killed before Swift cleanup code can run.
enum HostControlParentDeathSupervisor {
    struct LaunchPlan: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    static func launchPlan(
        executablePath: String,
        arguments: [String],
        lifetimeDescriptor: Int32
    ) -> LaunchPlan {
        precondition(lifetimeDescriptor >= 3)

        // The watchdog ignores TERM so it can escalate after giving the
        // supervised command group a bounded graceful-shutdown window. It is
        // disposable: normal completion cancels it with SIGKILL and reaps it.
        // This avoids relying on a trapped signal to interrupt macOS /bin/sh's
        // blocking `read`, which is not reliable when the host ignores that
        // signal itself.
        let script = """
        supervised_group="$$"
        (
          trap '' TERM HUP INT
          IFS= read -r _astra_parent_lifetime <&\(lifetimeDescriptor) || true
          kill -TERM -- "-$supervised_group" 2>/dev/null || true
          /bin/sleep 0.2
          kill -KILL -- "-$supervised_group" 2>/dev/null || true
        ) &
        watchdog_pid=$!
        exec \(lifetimeDescriptor)<&-
        "$@" &
        command_pid=$!
        wait "$command_pid"
        command_status=$?
        kill -KILL "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        exit "$command_status"
        """

        return LaunchPlan(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "astra-host-command-supervisor", executablePath] + arguments
        )
    }
}
