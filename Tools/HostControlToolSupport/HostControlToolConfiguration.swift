import Foundation

public struct HostControlToolConfiguration: Equatable, Sendable {
    public static let knownToolNames: Set<String> = ["github", "gcloud", "bq", "ssh", "jira", "redcap", "history"]

    public var githubExecutable: String
    public var gcloudExecutable: String
    public var bigQueryExecutable: String
    public var sshExecutable: String
    public var allowedSSHAliases: [String]
    public var sshRoute: HostControlSSHRoute?
    public var sshRouteTargets: [String]
    public var allowedTools: Set<String>
    public var currentDirectory: String
    /// Where a brokered tool writes output it must not return inline.
    ///
    /// No fallback. It used to fall back to `currentDirectory`, which is
    /// normally the workspace the agent is working in — usually a git checkout,
    /// so a REDCap export landing there was one `git add .` from committing
    /// subject data. A tool that has nowhere sanctioned to put its output must
    /// fail rather than choose somewhere.
    public var taskFolder: String
    public var diagnosticsHostPath: String
    public var taskID: String
    public var runID: String
    public var connectorsJSON: String
    public var environment: [String: String]

    public init(
        githubExecutable: String = "gh",
        gcloudExecutable: String = "gcloud",
        bigQueryExecutable: String = "bq",
        sshExecutable: String = "ssh",
        allowedSSHAliases: [String] = [],
        sshRoute: HostControlSSHRoute? = nil,
        sshRouteTargets: [String] = [],
        allowedTools: Set<String> = knownToolNames,
        currentDirectory: String = "",
        taskFolder: String = "",
        diagnosticsHostPath: String = "",
        taskID: String = "unknown-task",
        runID: String = "unknown-run",
        connectorsJSON: String = #"{"connectors":[]}"#,
        environment: [String: String] = [:]
    ) {
        self.githubExecutable = Self.clean(githubExecutable) ?? "gh"
        self.gcloudExecutable = Self.clean(gcloudExecutable) ?? "gcloud"
        self.bigQueryExecutable = Self.clean(bigQueryExecutable) ?? "bq"
        self.sshExecutable = Self.clean(sshExecutable) ?? "ssh"
        self.allowedSSHAliases = Self.deduplicated(allowedSSHAliases.compactMap(Self.clean))
        self.sshRoute = sshRoute
        self.sshRouteTargets = Self.deduplicated(sshRouteTargets.compactMap(Self.clean))
        let normalizedTools = Set(allowedTools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .intersection(Self.knownToolNames)
        self.allowedTools = normalizedTools
        self.currentDirectory = Self.clean(currentDirectory) ?? ""
        self.taskFolder = Self.clean(taskFolder) ?? ""
        self.diagnosticsHostPath = Self.clean(diagnosticsHostPath) ?? ""
        self.taskID = Self.clean(taskID) ?? "unknown-task"
        self.runID = Self.clean(runID) ?? "unknown-run"
        self.connectorsJSON = Self.clean(connectorsJSON) ?? #"{"connectors":[]}"#
        self.environment = environment
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HostControlToolConfiguration {
        HostControlToolConfiguration(
            githubExecutable: clean(env["ASTRA_HOST_CONTROL_GH_EXECUTABLE"]) ?? "gh",
            gcloudExecutable: clean(env["ASTRA_HOST_CONTROL_GCLOUD_EXECUTABLE"]) ?? "gcloud",
            bigQueryExecutable: clean(env["ASTRA_HOST_CONTROL_BQ_EXECUTABLE"]) ?? "bq",
            sshExecutable: clean(env["ASTRA_HOST_CONTROL_SSH_EXECUTABLE"]) ?? "ssh",
            allowedSSHAliases: splitList(env["ASTRA_HOST_CONTROL_ALLOWED_SSH_ALIASES"]),
            sshRoute: HostControlSSHRoute(wireValue: env[HostControlSSHRoute.environmentKey]),
            sshRouteTargets: (env[HostControlSSHRoute.targetsEnvironmentKey] ?? "").split(separator: "\n").map(String.init),
            allowedTools: allowedToolSet(env["ASTRA_HOST_CONTROL_ALLOWED_TOOLS"]),
            currentDirectory: clean(env["ASTRA_HOST_CONTROL_CURRENT_DIRECTORY"]) ?? "",
            taskFolder: clean(env["ASTRA_HOST_CONTROL_TASK_FOLDER"]) ?? "",
            diagnosticsHostPath: clean(env["ASTRA_HOST_CONTROL_DIAGNOSTICS_HOST"]) ?? "",
            taskID: clean(env["ASTRA_HOST_CONTROL_TASK_ID"]) ?? "unknown-task",
            runID: clean(env["ASTRA_HOST_CONTROL_RUN_ID"]) ?? "unknown-run",
            connectorsJSON: clean(env["ASTRA_CONNECTORS"]) ?? #"{"connectors":[]}"#,
            environment: env
        )
    }

    public var connectorManifest: HostControlConnectorManifest {
        (try? JSONDecoder().decode(HostControlConnectorManifest.self, from: Data(connectorsJSON.utf8)))
            ?? HostControlConnectorManifest(connectors: [])
    }

    private static func splitList(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map(String.init)
            .compactMap(clean)
    }

    private static func allowedToolSet(_ value: String?) -> Set<String> {
        guard value != nil else { return knownToolNames }
        return Set(splitList(value).map { $0.lowercased() }).intersection(knownToolNames)
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
