import Foundation

/// The POSIX `sh` scripts ASTRA sends to a host over `ssh <target> sh -s`.
///
/// They travel on stdin, so the agent's command is never re-quoted into an
/// `ssh` argument; it is written to `command.sh` through a quoted heredoc and
/// run there by the session's login shell, as `ssh <target> '<command>'`
/// would have run it. Every path is derived from a validated job id, so
/// nothing in a script names a location the caller chose.
public enum RemoteWorkspaceJobScripts {
    public static let probeMarker = "astra_probe"
    public static let tailMarker = "astra_tail"
    /// The `start` script's exit code when the job directory already exists.
    public static let existingJobExitCode: Int32 = 73
    /// The `start` script's exit code when the job root cannot be created.
    public static let unwritableRootExitCode: Int32 = 70
    public static let maximumTailLines = 500
    public static let maximumTailBytes = 64 * 1024
    /// How long `start` waits on the host for the launcher's evidence.
    static let launchEvidenceWaitTenths = 100

    public static func remoteDirectory(jobID: String) -> String {
        ".astra/jobs/\(jobID)"
    }

    public static func start(
        jobID: String,
        command: String,
        timeoutSeconds: Int?,
        makeDelimiter: () -> String = { "ASTRA_JOB_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    ) -> String {
        let launcherText = launcher(timeoutSeconds: timeoutSeconds)
        let commandDelimiter = delimiter(avoiding: command, make: makeDelimiter)
        let launcherDelimiter = delimiter(avoiding: launcherText, make: makeDelimiter)
        return """
        umask 077
        astra_root="$HOME/.astra"
        jobs_root="$astra_root/jobs"
        job_dir="$jobs_root/\(jobID)"
        if ! mkdir -p "$jobs_root"; then
          echo "astra_error=cannot create ~/.astra/jobs on this host"
          exit \(unwritableRootExitCode)
        fi
        chmod 700 "$astra_root" "$jobs_root" 2>/dev/null
        if ! mkdir "$job_dir" 2>/dev/null; then
          echo "astra_error=the job directory already exists on this host"
          exit \(existingJobExitCode)
        fi
        cat > "$job_dir/command.sh" <<'\(commandDelimiter)'
        \(command)
        \(commandDelimiter)
        cat > "$job_dir/launcher.sh" <<'\(launcherDelimiter)'
        \(launcherText)
        \(launcherDelimiter)
        if command -v setsid >/dev/null 2>&1; then
          nohup setsid sh "$job_dir/launcher.sh" "$job_dir" </dev/null >/dev/null 2>&1 &
        else
          nohup sh "$job_dir/launcher.sh" "$job_dir" </dev/null >/dev/null 2>&1 &
        fi
        waited=0
        while [ ! -s "$job_dir/process" ] && [ "$waited" -lt \(launchEvidenceWaitTenths) ]; do
          if sleep 0.1 2>/dev/null; then waited=$((waited + 1)); else sleep 1; waited=$((waited + 10)); fi
        done
        \(probeBody(jobID: jobID))
        """
    }

    public static func probe(jobID: String) -> String {
        probeBody(jobID: jobID)
    }

    public static func tail(jobID: String, stream: String, lines: Int) -> String {
        let file = stream == "stderr" ? "stderr.log" : "stdout.log"
        let count = max(1, min(lines, maximumTailLines))
        return """
        job_dir="$HOME/\(remoteDirectory(jobID: jobID))"
        if [ ! -d "$job_dir" ]; then
          echo "\(tailMarker)=missing"
          exit 0
        fi
        echo "\(tailMarker)=1"
        if [ -f "$job_dir/\(file)" ]; then
          tail -n \(count) "$job_dir/\(file)" | tail -c \(maximumTailBytes)
        fi
        """
    }

    /// Prints the probe marker, then `key=value` lines: the host's boot id,
    /// whether the job directory exists, the launcher's evidence, whether each
    /// recorded pid is alive with its current start marker, the result, and
    /// both logs' size and mtime. The pids are checked before the result is
    /// read, so a job finishing mid-probe is seen as finished, never lost.
    private static func probeBody(jobID: String) -> String {
        """
        \(hostFunctions)
        job_dir="$HOME/\(remoteDirectory(jobID: jobID))"
        echo "\(probeMarker)=1"
        printf 'host_boot_id=%s\\n' "$(astra_boot_id)"
        if [ ! -d "$job_dir" ]; then
          echo "state=missing"
          exit 0
        fi
        echo "state=present"
        pid=""
        supervisor_pid=""
        if [ -r "$job_dir/process" ]; then
          sed 's/^/evidence./' "$job_dir/process"
          pid="$(sed -n 's/^pid=//p' "$job_dir/process")"
          supervisor_pid="$(sed -n 's/^supervisor_pid=//p' "$job_dir/process")"
        fi
        if astra_alive "$pid"; then
          echo "pid_alive=1"
          printf 'pid_start_marker=%s\\n' "$(astra_start_marker "$pid")"
        else
          echo "pid_alive=0"
        fi
        if astra_alive "$supervisor_pid"; then
          echo "supervisor_alive=1"
          printf 'supervisor_start_marker=%s\\n' "$(astra_start_marker "$supervisor_pid")"
        else
          echo "supervisor_alive=0"
        fi
        if [ -r "$job_dir/result.json" ]; then
          printf 'result=%s\\n' "$(head -c 4096 "$job_dir/result.json" | tr -d '\\n')"
        fi
        for stream in stdout stderr; do
          log="$job_dir/$stream.log"
          if [ -f "$log" ]; then
            printf '%s_bytes=%s\\n' "$stream" "$(wc -c < "$log" | tr -d ' ')"
            printf '%s_mtime=%s\\n' "$stream" "$(stat -c %Y "$log" 2>/dev/null || stat -f %m "$log" 2>/dev/null)"
          fi
        done
        exit 0
        """
    }

    /// Shared by the probe and the launcher, so both describe a process the
    /// same way. The boot id is Linux's; macOS hosts fall back to the boot
    /// time, which is just as unique per boot.
    private static let hostFunctions = """
    astra_boot_id() {
      if [ -r /proc/sys/kernel/random/boot_id ]; then
        cat /proc/sys/kernel/random/boot_id
      else
        sysctl -n kern.boottime 2>/dev/null | sed 's/ usec.*//'
      fi
    }
    astra_start_marker() {
      ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'
    }
    astra_alive() {
      case "$1" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "$1" -gt 1 ] && kill -0 "$1" 2>/dev/null
    }
    """

    /// The supervisor. It runs the command in `$HOME` with the session's login
    /// shell, in its own process group where `setsid` exists, writes the
    /// launch evidence and then the result, each by atomic rename.
    static func launcher(timeoutSeconds: Int?) -> String {
        let timeout = max(0, timeoutSeconds ?? 0)
        return """
        \(hostFunctions)
        job_dir="$1"
        timeout_seconds=\(timeout)
        cd "$HOME" 2>/dev/null || cd /
        job_shell="${SHELL:-/bin/sh}"
        [ -x "$job_shell" ] || job_shell=/bin/sh
        if command -v setsid >/dev/null 2>&1; then
          isolation=setsid
          setsid "$job_shell" "$job_dir/command.sh" </dev/null >"$job_dir/stdout.log" 2>"$job_dir/stderr.log" &
        else
          isolation=nohup
          "$job_shell" "$job_dir/command.sh" </dev/null >"$job_dir/stdout.log" 2>"$job_dir/stderr.log" &
        fi
        pid=$!
        {
          printf 'pid=%s\\n' "$pid"
          printf 'start_marker=%s\\n' "$(astra_start_marker "$pid")"
          printf 'supervisor_pid=%s\\n' "$$"
          printf 'supervisor_start_marker=%s\\n' "$(astra_start_marker "$$")"
          printf 'boot_id=%s\\n' "$(astra_boot_id)"
          printf 'started_at=%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf 'isolation=%s\\n' "$isolation"
          printf 'shell=%s\\n' "$job_shell"
        } > "$job_dir/process.tmp" && mv -f "$job_dir/process.tmp" "$job_dir/process"
        timer_pid=""
        if [ "$timeout_seconds" -gt 0 ]; then
          (
            elapsed=0
            while [ "$elapsed" -lt "$timeout_seconds" ]; do
              sleep 5
              elapsed=$((elapsed + 5))
              kill -0 "$pid" 2>/dev/null || exit 0
            done
            : > "$job_dir/timed_out"
            if [ "$isolation" = setsid ]; then kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; else kill -TERM "$pid" 2>/dev/null; fi
            sleep 5
            if [ "$isolation" = setsid ]; then kill -KILL -- "-$pid" 2>/dev/null; fi
            kill -KILL "$pid" 2>/dev/null
          ) </dev/null >/dev/null 2>&1 &
          timer_pid=$!
        fi
        wait "$pid"
        code=$?
        if [ -n "$timer_pid" ]; then
          kill "$timer_pid" 2>/dev/null
        fi
        status=failed
        if [ "$code" -eq 0 ]; then status=succeeded; fi
        if [ -f "$job_dir/timed_out" ]; then status=timed_out; code=124; fi
        printf '{"status":"%s","exit_code":%s,"completed_at":"%s"}\\n' "$status" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$job_dir/result.tmp" && mv -f "$job_dir/result.tmp" "$job_dir/result.json"
        exit 0
        """
    }

    /// A heredoc delimiter that no line of `text` equals, so the text can
    /// never close its own heredoc early.
    static func delimiter(avoiding text: String, make: () -> String) -> String {
        let lines = Set(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        var candidate = make()
        while lines.contains(candidate) {
            candidate = make() + "_"
        }
        return candidate
    }
}
