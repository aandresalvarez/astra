import Foundation

public enum WorkspaceManagedJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"
}

public struct WorkspaceManagedJobRecord: Codable, Equatable, Sendable {
    public var jobID: String
    public var command: String
    public var label: String?
    public var progressProbe: String?
    public var runtime: String
    public var status: WorkspaceManagedJobStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date
    public var completedAt: Date?
    public var lastHeartbeatAt: Date?
    public var lastOutputAt: Date?
    public var timeoutSeconds: TimeInterval?
    public var exitCode: Int32?
    public var stdoutLogPath: String
    public var stderrLogPath: String
    public var heartbeatPath: String
    public var resultPath: String
    public var message: String?

    public init(
        jobID: String,
        command: String,
        label: String? = nil,
        progressProbe: String? = nil,
        runtime: String,
        status: WorkspaceManagedJobStatus,
        createdAt: Date,
        startedAt: Date? = nil,
        updatedAt: Date,
        completedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        lastOutputAt: Date? = nil,
        timeoutSeconds: TimeInterval? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String,
        stderrLogPath: String,
        heartbeatPath: String,
        resultPath: String,
        message: String? = nil
    ) {
        self.jobID = jobID
        self.command = command
        self.label = label
        self.progressProbe = progressProbe
        self.runtime = runtime
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastOutputAt = lastOutputAt
        self.timeoutSeconds = timeoutSeconds
        self.exitCode = exitCode
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
        self.heartbeatPath = heartbeatPath
        self.resultPath = resultPath
        self.message = message
    }

    public var isTerminal: Bool {
        switch status {
        case .queued, .running:
            return false
        case .succeeded, .failed, .cancelled, .timedOut:
            return true
        }
    }
}

public struct WorkspaceManagedJobTail: Equatable, Sendable {
    public var jobID: String
    public var stream: String
    public var text: String

    public init(jobID: String, stream: String, text: String) {
        self.jobID = jobID
        self.stream = stream
        self.text = text
    }
}

public protocol WorkspaceJobManaging: AnyObject {
    func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord
    func status(jobID: String) -> WorkspaceManagedJobRecord
    func tail(jobID: String, stream: String, lines: Int) -> WorkspaceManagedJobTail
    func cancel(jobID: String) -> WorkspaceManagedJobRecord
    func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord
}

public final class WorkspaceManagedJobStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootPath: String, fileManager: FileManager = .default) {
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func makeJobID() -> String {
        UUID().uuidString.lowercased()
    }

    public func jobDirectory(jobID: String) -> URL {
        rootURL.appendingPathComponent(safeJobID(jobID), isDirectory: true)
    }

    public func create(command: String, timeoutSeconds: TimeInterval?, label: String?, progressProbe: String?, runtime: String) throws -> WorkspaceManagedJobRecord {
        let jobID = makeJobID()
        let directory = jobDirectory(jobID: jobID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let commandURL = directory.appendingPathComponent("command.sh", isDirectory: false)
        try ("#!/bin/sh\n" + command + "\n").write(to: commandURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandURL.path)

        let now = Date()
        let record = WorkspaceManagedJobRecord(
            jobID: jobID,
            command: command,
            label: label,
            progressProbe: progressProbe,
            runtime: runtime,
            status: .queued,
            createdAt: now,
            updatedAt: now,
            timeoutSeconds: timeoutSeconds,
            stdoutLogPath: directory.appendingPathComponent("stdout.log", isDirectory: false).path,
            stderrLogPath: directory.appendingPathComponent("stderr.log", isDirectory: false).path,
            heartbeatPath: directory.appendingPathComponent("heartbeat.json", isDirectory: false).path,
            resultPath: directory.appendingPathComponent("result.json", isDirectory: false).path
        )
        try save(record)
        return record
    }

    public func save(_ record: WorkspaceManagedJobRecord) throws {
        let directory = jobDirectory(jobID: record.jobID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("job.json", isDirectory: false), options: [.atomic])
    }

    public func load(jobID: String) throws -> WorkspaceManagedJobRecord {
        let directory = jobDirectory(jobID: jobID)
        let data = try Data(contentsOf: directory.appendingPathComponent("job.json", isDirectory: false))
        var record = try decoder.decode(WorkspaceManagedJobRecord.self, from: data)
        applyRuntimeFiles(to: &record, directory: directory)
        return record
    }

    public func tail(jobID: String, stream: String, lines: Int) throws -> WorkspaceManagedJobTail {
        let record = try load(jobID: jobID)
        let normalizedStream = stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = normalizedStream == "stderr" ? record.stderrLogPath : record.stdoutLogPath
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return WorkspaceManagedJobTail(
            jobID: record.jobID,
            stream: normalizedStream == "stderr" ? "stderr" : "stdout",
            text: lastLines(text, count: lines)
        )
    }

    public func mark(jobID: String, status: WorkspaceManagedJobStatus, message: String? = nil, exitCode: Int32? = nil) throws -> WorkspaceManagedJobRecord {
        var record = try load(jobID: jobID)
        record.status = status
        record.updatedAt = Date()
        if status != .queued && status != .running {
            record.completedAt = record.updatedAt
        }
        if let message {
            record.message = message
        }
        if let exitCode {
            record.exitCode = exitCode
        }
        try save(record)
        return record
    }

    private func applyRuntimeFiles(to record: inout WorkspaceManagedJobRecord, directory: URL) {
        let heartbeatURL = directory.appendingPathComponent("heartbeat.json", isDirectory: false)
        if let heartbeat = try? RuntimeHeartbeat.read(from: heartbeatURL, decoder: decoder) {
            record.lastHeartbeatAt = heartbeat.timestamp
            if record.status == .queued {
                record.status = .running
            }
        }

        let stdoutURL = URL(fileURLWithPath: record.stdoutLogPath, isDirectory: false)
        let stderrURL = URL(fileURLWithPath: record.stderrLogPath, isDirectory: false)
        record.lastOutputAt = [stdoutURL, stderrURL]
            .compactMap { (try? fileManager.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
            .max()

        let resultURL = directory.appendingPathComponent("result.json", isDirectory: false)
        if let result = try? RuntimeResult.read(from: resultURL, decoder: decoder) {
            record.status = result.status
            record.exitCode = result.exitCode
            record.completedAt = result.completedAt
            record.updatedAt = result.completedAt
            record.message = result.message ?? record.message
        }
    }

    private func safeJobID(_ raw: String) -> String {
        let filtered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "unknown-job" : String(filtered.prefix(80))
    }

    private func lastLines(_ text: String, count: Int) -> String {
        let limit = max(1, min(count, 10_000))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.suffix(limit).joined(separator: "\n")
    }

    private struct RuntimeHeartbeat: Codable {
        var status: WorkspaceManagedJobStatus
        var timestamp: Date

        static func read(from url: URL, decoder: JSONDecoder) throws -> RuntimeHeartbeat {
            try decoder.decode(RuntimeHeartbeat.self, from: Data(contentsOf: url))
        }
    }

    private struct RuntimeResult: Codable {
        var status: WorkspaceManagedJobStatus
        var exitCode: Int32?
        var completedAt: Date
        var message: String?

        static func read(from url: URL, decoder: JSONDecoder) throws -> RuntimeResult {
            try decoder.decode(RuntimeResult.self, from: Data(contentsOf: url))
        }
    }
}

public final class DockerWorkspaceJobManager: WorkspaceJobManaging {
    private let configuration: WorkspaceToolConfiguration
    private let executor: DockerWorkspaceCommandExecutor
    private let store: WorkspaceManagedJobStore

    public init(configuration: WorkspaceToolConfiguration, executor: DockerWorkspaceCommandExecutor) {
        self.configuration = configuration
        self.executor = executor
        self.store = WorkspaceManagedJobStore(rootPath: configuration.jobRootHostPath)
    }

    public func start(
        command: String,
        timeoutSeconds: TimeInterval?,
        label: String?,
        progressProbe: String?
    ) -> WorkspaceManagedJobRecord {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return failedSynthetic(command: command, message: "workspace_job_start requires a non-empty command")
        }
        let pathResolution = configuration.containerCommand(for: trimmed)
        if let errorMessage = pathResolution.errorMessage {
            return failedSynthetic(command: command, message: errorMessage)
        }
        let container = executor.ensureContainerStarted()
        guard container.exitCode == 0 else {
            return failedSynthetic(
                command: command,
                message: container.stderr.isEmpty ? "Failed to start Docker workspace container" : container.stderr
            )
        }

        do {
            var record = try store.create(
                command: pathResolution.command,
                timeoutSeconds: timeoutSeconds,
                label: label,
                progressProbe: progressProbe,
                runtime: "docker"
            )
            record.status = .running
            record.startedAt = Date()
            record.updatedAt = record.startedAt ?? record.updatedAt
            try store.save(record)

            let result = executor.runDockerCommand(
                arguments: [
                    "exec", "-d",
                    "--workdir", configuration.workdir,
                    configuration.containerName,
                    "sh", "-c", wrapperScript(
                        containerJobDirectory: containerJobDirectory(jobID: record.jobID),
                        timeoutSeconds: timeoutSeconds
                    )
                ],
                commandLabel: "workspace_job_start \(record.jobID)",
                timeoutSeconds: 30
            )
            guard result.exitCode == 0 else {
                return try store.mark(
                    jobID: record.jobID,
                    status: .failed,
                    message: result.stderr.isEmpty ? "Docker could not start the managed workspace job." : result.stderr,
                    exitCode: result.exitCode
                )
            }
            return try store.load(jobID: record.jobID)
        } catch {
            return failedSynthetic(command: command, message: error.localizedDescription)
        }
    }

    public func status(jobID: String) -> WorkspaceManagedJobRecord {
        do {
            return try store.load(jobID: jobID)
        } catch {
            return failedSynthetic(command: "", jobID: jobID, message: error.localizedDescription)
        }
    }

    public func tail(jobID: String, stream: String, lines: Int) -> WorkspaceManagedJobTail {
        do {
            return try store.tail(jobID: jobID, stream: stream, lines: lines)
        } catch {
            return WorkspaceManagedJobTail(jobID: jobID, stream: stream, text: error.localizedDescription)
        }
    }

    public func cancel(jobID: String) -> WorkspaceManagedJobRecord {
        let directory = containerJobDirectory(jobID: jobID)
        _ = executor.runDockerCommand(
            arguments: [
                "exec", configuration.containerName,
                "sh", "-c",
                """
                pidfile=\(shellQuote(directory + "/pid"))
                pid_metadata=\(shellQuote(directory + "/pid.meta"))
                command_script=\(shellQuote(directory + "/command.sh"))
                kill_bin=""
                for candidate in /bin/kill /usr/bin/kill /usr/local/bin/kill; do
                  if [ -x "$candidate" ]; then
                    kill_bin="$candidate"
                    break
                  fi
                done
                safe_pid() {
                  case "$1" in
                    ''|*[!0-9]*) return 1 ;;
                  esac
                  [ "$1" -gt 1 ] 2>/dev/null
                }
                proc_start_time() {
                  safe_pid "$1" || return 1
                  [ -r "/proc/$1/stat" ] || return 1
                  stat_line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
                  stat_rest="${stat_line##*) }"
                  set -- $stat_rest
                  [ "$#" -ge 20 ] || return 1
                  shift 19
                  printf '%s\\n' "$1"
                }
                proc_is_session_group_leader() {
                  target_pid="$1"
                  safe_pid "$target_pid" || return 1
                  [ -r "/proc/$target_pid/stat" ] || return 1
                  stat_line="$(cat "/proc/$target_pid/stat" 2>/dev/null || true)"
                  stat_rest="${stat_line##*) }"
                  set -- $stat_rest
                  [ "$#" -ge 4 ] || return 1
                  [ "$3" = "$target_pid" ] && [ "$4" = "$target_pid" ]
                }
                pid_matches_managed_command() {
                  safe_pid "$1" || return 1
                  [ -r "/proc/$1/cmdline" ] || return 1
                  cmdline="$(tr '\\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || cat "/proc/$1/cmdline" 2>/dev/null || true)"
                  case "$cmdline" in
                    *"$command_script"*) return 0 ;;
                    *) return 1 ;;
                  esac
                }
                pid_matches_managed_session() {
                  safe_pid "$1" || return 1
                  [ -r "$pid_metadata" ] || return 1
                  managed_pid=""
                  managed_mode=""
                  managed_start_time=""
                  while IFS='=' read -r key value; do
                    case "$key" in
                      pid) managed_pid="$value" ;;
                      mode) managed_mode="$value" ;;
                      start_time) managed_start_time="$value" ;;
                    esac
                  done < "$pid_metadata"
                  [ "$managed_pid" = "$1" ] || return 1
                  [ "$managed_mode" = "setsid-process-group" ] || return 1
                  [ -n "$managed_start_time" ] || return 1
                  current_start_time="$(proc_start_time "$1" || true)"
                  [ "$managed_start_time" = "$current_start_time" ] || return 1
                  proc_is_session_group_leader "$1"
                }
                pid_metadata_names_managed_group() {
                  safe_pid "$1" || return 1
                  [ -r "$pid_metadata" ] || return 1
                  managed_pid=""
                  managed_mode=""
                  while IFS='=' read -r key value; do
                    case "$key" in
                      pid) managed_pid="$value" ;;
                      mode) managed_mode="$value" ;;
                    esac
                  done < "$pid_metadata"
                  [ "$managed_pid" = "$1" ] || return 1
                  [ "$managed_mode" = "setsid-process-group" ]
                }
                process_group_exists() {
                  group_pid="$1"
                  safe_pid "$group_pid" || return 1
                  if [ -n "$kill_bin" ] && "$kill_bin" -0 -- -"$group_pid" 2>/dev/null; then
                    return 0
                  fi
                  kill -0 -"$group_pid" 2>/dev/null
                }
                signal_process_group() {
                  signal="$1"
                  group_pid="$2"
                  safe_pid "$group_pid" || return 0
                  if [ -n "$kill_bin" ] && "$kill_bin" -"$signal" -- -"$group_pid" 2>/dev/null; then
                    return 0
                  fi
                  kill -"$signal" -"$group_pid" 2>/dev/null || true
                }
                signal_direct_pid() {
                  signal="$1"
                  target_pid="$2"
                  safe_pid "$target_pid" || return 0
                  kill -"$signal" "$target_pid" 2>/dev/null || true
                }
                terminate_verified_process_group() {
                  group_pid="$1"
                  if process_group_exists "$group_pid"; then
                    signal_process_group TERM "$group_pid"
                    sleep 5
                    signal_process_group KILL "$group_pid"
                  fi
                }
                terminate_direct_pid() {
                  target_pid="$1"
                  if kill -0 "$target_pid" 2>/dev/null; then
                    signal_direct_pid TERM "$target_pid"
                    sleep 5
                    signal_direct_pid KILL "$target_pid"
                  fi
                }
                terminate_pid_or_group() {
                  target_pid="$1"
                  safe_pid "$target_pid" || return 0
                  if pid_metadata_names_managed_group "$target_pid"; then
                    if kill -0 "$target_pid" 2>/dev/null; then
                      if pid_matches_managed_session "$target_pid"; then
                        if process_group_exists "$target_pid"; then
                          terminate_verified_process_group "$target_pid"
                        else
                          terminate_direct_pid "$target_pid"
                        fi
                      fi
                    elif process_group_exists "$target_pid"; then
                      terminate_verified_process_group "$target_pid"
                    fi
                  elif pid_matches_managed_command "$target_pid"; then
                    if proc_is_session_group_leader "$target_pid"; then
                      terminate_verified_process_group "$target_pid"
                    else
                      terminate_direct_pid "$target_pid"
                    fi
                  elif [ ! -e "$pid_metadata" ] && kill -0 "$target_pid" 2>/dev/null; then
                    terminate_direct_pid "$target_pid"
                  fi
                }
                if [ -r "$pidfile" ]; then
                  IFS= read -r command_pid < "$pidfile" || command_pid=""
                  terminate_pid_or_group "$command_pid"
                  rm -f "$pidfile" "$pid_metadata"
                fi
                """
            ],
            commandLabel: "workspace_job_cancel \(jobID)",
            timeoutSeconds: 10
        )
        do {
            return try store.mark(jobID: jobID, status: .cancelled, message: "Cancelled by ASTRA.")
        } catch {
            return failedSynthetic(command: "", jobID: jobID, message: error.localizedDescription)
        }
    }

    public func wait(jobID: String, timeoutSeconds: TimeInterval) -> WorkspaceManagedJobRecord {
        let deadline = Date().addingTimeInterval(max(1, timeoutSeconds))
        var latest = status(jobID: jobID)
        while !latest.isTerminal && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            latest = status(jobID: jobID)
        }
        return latest
    }

    private func containerJobDirectory(jobID: String) -> String {
        configuration.jobRootContainerPath + "/" + jobID
    }

    private func wrapperScript(containerJobDirectory: String, timeoutSeconds: TimeInterval?) -> String {
        let dir = shellQuote(containerJobDirectory)
        let timeout = max(0, Int((timeoutSeconds ?? 0).rounded(.up)))
        return """
        job_dir=\(dir)
        timeout_seconds=\(timeout)
        stdout="$job_dir/stdout.log"
        stderr="$job_dir/stderr.log"
        heartbeat="$job_dir/heartbeat.json"
        result="$job_dir/result.json"
        pidfile="$job_dir/pid"
        pid_metadata="$job_dir/pid.meta"
        timeout_marker="$job_dir/timeout"
        mkdir -p "$job_dir"
        rm -f "$timeout_marker" "$pidfile" "$pid_metadata"
        kill_bin=""
        for candidate in /bin/kill /usr/bin/kill /usr/local/bin/kill; do
          if [ -x "$candidate" ]; then
            kill_bin="$candidate"
            break
          fi
        done
        setsid_bin=""
        for candidate in /usr/bin/setsid /bin/setsid /usr/sbin/setsid /sbin/setsid /usr/local/bin/setsid; do
          if [ -x "$candidate" ]; then
            setsid_bin="$candidate"
            break
          fi
        done
        (
          while :; do
            printf '{"status":"running","timestamp":"%s"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
            sleep 10
          done
        ) &
        heartbeat_pid=$!
        if [ -z "$setsid_bin" ]; then
          printf '%s\\n' "setsid is required for managed job process-group isolation." > "$stderr"
          kill "$heartbeat_pid" 2>/dev/null || true
          wait "$heartbeat_pid" 2>/dev/null || true
          printf '{"status":"failed","exitCode":127,"completedAt":"%s","message":"process group isolation unavailable"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$result"
          printf '{"status":"failed","timestamp":"%s"}\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
          exit 0
        fi
        safe_pid() {
          case "$1" in
            ''|*[!0-9]*) return 1 ;;
          esac
          [ "$1" -gt 1 ] 2>/dev/null
        }
        proc_start_time() {
          safe_pid "$1" || return 1
          [ -r "/proc/$1/stat" ] || return 1
          stat_line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
          stat_rest="${stat_line##*) }"
          set -- $stat_rest
          [ "$#" -ge 20 ] || return 1
          shift 19
          printf '%s\\n' "$1"
        }
        "$setsid_bin" sh "$job_dir/command.sh" > "$stdout" 2> "$stderr" &
        command_pid=$!
        printf '%s\\n' "$command_pid" > "$pidfile"
        command_start_time="$(proc_start_time "$command_pid" || true)"
        if [ -n "$command_start_time" ]; then
          {
            printf 'version=1\\n'
            printf 'mode=setsid-process-group\\n'
            printf 'pid=%s\\n' "$command_pid"
            printf 'start_time=%s\\n' "$command_start_time"
          } > "$pid_metadata"
        else
          rm -f "$pid_metadata"
        fi
        process_group_exists() {
          group_pid="$1"
          safe_pid "$group_pid" || return 1
          if [ -n "$kill_bin" ] && "$kill_bin" -0 -- -"$group_pid" 2>/dev/null; then
            return 0
          fi
          kill -0 -"$group_pid" 2>/dev/null
        }
        signal_process_group() {
          signal="$1"
          group_pid="$2"
          safe_pid "$group_pid" || return 0
          if [ -n "$kill_bin" ] && "$kill_bin" -"$signal" -- -"$group_pid" 2>/dev/null; then
            return 0
          fi
          kill -"$signal" -"$group_pid" 2>/dev/null || true
        }
        terminate_command_group() {
          grace_seconds="${1:-5}"
          safe_pid "$command_pid" || return 0
          if process_group_exists "$command_pid"; then
            signal_process_group TERM "$command_pid"
            sleep "$grace_seconds"
            signal_process_group KILL "$command_pid"
          fi
        }
        command_leader_matches_start_time() {
          safe_pid "$command_pid" || return 1
          kill -0 "$command_pid" 2>/dev/null || return 1
          if [ -n "$command_start_time" ]; then
            current_start_time="$(proc_start_time "$command_pid" || true)"
            [ "$command_start_time" = "$current_start_time" ] || return 1
          fi
          return 0
        }
        timeout_pid=""
        if [ "$timeout_seconds" -gt 0 ]; then
          (
            sleep "$timeout_seconds"
            if command_leader_matches_start_time && process_group_exists "$command_pid"; then
              printf '%s\\n' timed_out > "$timeout_marker"
              terminate_command_group 5
            fi
          ) &
          timeout_pid=$!
        fi
        wait "$command_pid"
        code=$?
        if [ -n "$timeout_pid" ]; then
          kill "$timeout_pid" 2>/dev/null || true
          wait "$timeout_pid" 2>/dev/null || true
        fi
        terminate_command_group 1
        rm -f "$pidfile" "$pid_metadata"
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
        status=failed
        if [ "$code" -eq 0 ]; then status=succeeded; fi
        if [ -f "$timeout_marker" ]; then status=timed_out; code=124; fi
        printf '{"status":"%s","exitCode":%s,"completedAt":"%s"}\\n' "$status" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$result"
        printf '{"status":"%s","timestamp":"%s"}\\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$heartbeat"
        exit 0
        """
    }

    private func failedSynthetic(command: String, jobID: String = "unstarted", message: String) -> WorkspaceManagedJobRecord {
        let now = Date()
        return WorkspaceManagedJobRecord(
            jobID: jobID,
            command: command,
            runtime: "docker",
            status: .failed,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            exitCode: 2,
            stdoutLogPath: "",
            stderrLogPath: "",
            heartbeatPath: "",
            resultPath: "",
            message: message
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
