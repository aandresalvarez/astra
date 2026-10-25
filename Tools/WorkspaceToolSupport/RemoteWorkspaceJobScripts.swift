import Foundation

/// Bounded SSH operations. Cancellation writes an intent for the original
/// supervisor; no operation signals a PID supplied by a record or caller.
public enum RemoteWorkspaceJobScripts {
    public static let probeMarker = "astra_probe"
    public static let tailMarker = "astra_tail"
    public static let existingJobExitCode: Int32 = 73
    public static let unwritableRootExitCode: Int32 = 70
    public static let maximumTailLines = 500
    public static let maximumTailBytes = 64 * 1024

    public static func remoteDirectory(jobID: String) -> String { ".astra/jobs/\(jobID)" }

    public static func start(jobID: String, command: String, timeoutSeconds: Int?,
        nonce: String = UUID().uuidString.lowercased(), clock: RemoteWorkspaceJobClock.Reference,
        makeDelimiter: () -> String = { "ASTRA_JOB_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    ) -> String {
        let clockData = (try? JSONEncoder().encode(clock))?.base64EncodedString() ?? ""
        let commandDelimiter = delimiter(avoiding: command, make: makeDelimiter)
        let supervisorDelimiter = delimiter(avoiding: RemoteWorkspaceJobSupervisor.source, make: makeDelimiter)
        return """
        set -e
        umask 077
        command -v python3 >/dev/null 2>&1 || { echo 'astra_error=Python 3.9 or newer is required on the SSH host'; exit \(unwritableRootExitCode); }
        python3 -c 'import sys; sys.exit(sys.version_info < (3,9))' || exit \(unwritableRootExitCode)
        astra_root="$HOME/.astra"
        jobs_root="$astra_root/jobs"
        job_dir="$jobs_root/\(jobID)"
        if [ -L "$astra_root" ] || [ -L "$jobs_root" ]; then exit \(unwritableRootExitCode); fi
        mkdir -p "$jobs_root" || exit \(unwritableRootExitCode)
        chmod 700 "$astra_root" "$jobs_root" || exit \(unwritableRootExitCode)
        if ! mkdir "$job_dir" 2>/dev/null; then
          echo 'astra_error=the job directory already exists on this host'
          exit \(existingJobExitCode)
        fi
        printf '%s' '\(nonce)' > "$job_dir/nonce" || exit \(unwritableRootExitCode)
        cat > "$job_dir/command.sh" <<'\(commandDelimiter)'
        \(command)
        \(commandDelimiter)
        cat > "$job_dir/supervisor.py" <<'\(supervisorDelimiter)'
        \(RemoteWorkspaceJobSupervisor.source)
        \(supervisorDelimiter)
        nohup python3 "$job_dir/supervisor.py" "$job_dir" '\(nonce)' '\(max(0, timeoutSeconds ?? 0))' "${SHELL:-/bin/sh}" '\(clockData)' </dev/null >/dev/null 2>"$job_dir/supervisor.log" &
        count=0
        while [ ! -s "$job_dir/process.json" ] && [ "$count" -lt 100 ]; do
          sleep 0.1
          count=$((count + 1))
        done
        \(probe(jobID: jobID, nonce: nonce))
        """
    }

    public static func probe(jobID: String, nonce: String = "legacy") -> String {
        python(jobID: jobID, nonce: nonce, operation: "probe")
    }

    public static func cancel(jobID: String, nonce: String) -> String {
        python(jobID: jobID, nonce: nonce, operation: "cancel")
    }

    public static func tail(jobID: String, stream: String, lines: Int, nonce: String = "legacy") -> String {
        python(jobID: jobID, nonce: nonce, operation: "tail", stream: stream,
            lines: max(1, min(lines, maximumTailLines)))
    }

    private static func python(jobID: String, nonce: String, operation: String, stream: String = "stdout", lines: Int = 120) -> String {
        """
        python3 - '\(jobID)' '\(nonce)' '\(operation)' '\(stream)' '\(lines)' <<'ASTRA_JOB_PROBE_PY'
        \(RemoteWorkspaceJobProbe.source)
        ASTRA_JOB_PROBE_PY
        """
    }

    static func delimiter(avoiding text: String, make: () -> String) -> String {
        let lines = Set(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        var candidate = make()
        while lines.contains(candidate) { candidate = make() + "_" }
        return candidate
    }
}
