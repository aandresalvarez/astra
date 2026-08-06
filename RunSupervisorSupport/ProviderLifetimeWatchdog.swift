import Foundation

/// Builds the fail-stop wrapper used for app-owned provider processes.
///
/// macOS has no equivalent of Linux `PR_SET_PDEATHSIG`. The ASTRA owner keeps
/// the write end of a private pipe open and only the watchdog inherits its read
/// end. A SIGKILL, crash, or ordinary owner exit closes the write end in the
/// kernel, so EOF is an authoritative owner-death signal that does not depend
/// on Swift cleanup handlers running.
enum ProviderLifetimeWatchdog {
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

        // The watchdog ignores graceful signals so it remains available to
        // perform the bounded escalation. It is part of the supervised process
        // group and is force-reaped by the supervisor after provider completion.
        // The shell must exec the provider so waitpid observes the provider's
        // original exit or signal status instead of a shell-normalized 128+signal.
        let script = """
        supervised_group="$$"
        (
          trap '' TERM HUP INT
          IFS= read -r _astra_owner_lifetime <&\(lifetimeDescriptor) || true
          /bin/kill -TERM -- "-$supervised_group" 2>/dev/null || true
          /bin/sleep 0.2
          /bin/kill -KILL -- "-$supervised_group" 2>/dev/null || true
        ) &
        exec \(lifetimeDescriptor)<&-
        exec "$@"
        """

        return LaunchPlan(
            executablePath: "/bin/sh",
            arguments: ["-c", script, "astra-provider-supervisor", executablePath] + arguments
        )
    }
}
