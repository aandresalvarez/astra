import Foundation

public struct WorkspaceDockerMount: Codable, Equatable, Sendable {
    public var hostPath: String
    public var containerPath: String
    public var access: String
    public var role: String

    public init(hostPath: String, containerPath: String, access: String, role: String) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.access = access
        self.role = role
    }
}

public struct WorkspaceToolConfiguration: Equatable, Sendable {
    public var dockerExecutable: String
    public var image: String
    public var containerName: String
    public var workdir: String
    public var network: String
    public var taskID: String
    public var runID: String
    public var mounts: [WorkspaceDockerMount]
    public var containerEnvironment: [String: String]
    public var jobRootHostPath: String
    public var jobRootContainerPath: String
    public var dockerClientConfigPath: String
    public var diagnosticsHostPath: String
    public var subagentParentID: String?

    public init(
        dockerExecutable: String,
        image: String,
        containerName: String,
        workdir: String,
        network: String,
        taskID: String,
        runID: String,
        mounts: [WorkspaceDockerMount],
        containerEnvironment: [String: String] = [:],
        jobRootHostPath: String? = nil,
        jobRootContainerPath: String? = nil,
        dockerClientConfigPath: String? = nil,
        diagnosticsHostPath: String? = nil,
        subagentParentID: String? = nil
    ) {
        self.dockerExecutable = dockerExecutable
        self.image = image
        self.containerName = containerName
        self.workdir = workdir
        self.network = network
        self.taskID = taskID
        self.runID = runID
        self.mounts = mounts
        var normalizedEnvironment = Self.normalizedContainerEnvironment(containerEnvironment)
        if normalizedEnvironment["PATH"] == nil {
            normalizedEnvironment["PATH"] = Self.defaultContainerPATH(mounts: mounts)
        }
        self.containerEnvironment = normalizedEnvironment
        self.jobRootHostPath = Self.clean(jobRootHostPath) ?? Self.defaultJobRootHostPath(taskID: taskID, mounts: mounts)
        self.jobRootContainerPath = Self.clean(jobRootContainerPath) ?? Self.defaultJobRootContainerPath(taskID: taskID, mounts: mounts)
        self.dockerClientConfigPath = Self.clean(dockerClientConfigPath)
            ?? Self.defaultDockerClientConfigPath(jobRootHostPath: self.jobRootHostPath, runID: runID)
        self.diagnosticsHostPath = Self.clean(diagnosticsHostPath)
            ?? Self.defaultDiagnosticsHostPath(jobRootHostPath: self.jobRootHostPath)
        self.subagentParentID = Self.clean(subagentParentID)
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkspaceToolConfiguration {
        let dockerExecutable = clean(env["ASTRA_WORKSPACE_DOCKER_EXECUTABLE"]) ?? "docker"
        guard let image = clean(env["ASTRA_WORKSPACE_DOCKER_IMAGE"]) else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_IMAGE is required")
        }
        guard let containerName = clean(env["ASTRA_WORKSPACE_DOCKER_CONTAINER"]) else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_CONTAINER is required")
        }
        let workdir = clean(env["ASTRA_WORKSPACE_DOCKER_WORKDIR"]) ?? "/workspace"
        let network = clean(env["ASTRA_WORKSPACE_DOCKER_NETWORK"]) ?? "bridge"
        let taskID = clean(env["ASTRA_WORKSPACE_TASK_ID"]) ?? "unknown-task"
        let runID = clean(env["ASTRA_WORKSPACE_RUN_ID"]) ?? "unknown-run"
        let mountsJSON = clean(env["ASTRA_WORKSPACE_DOCKER_MOUNTS"]) ?? "[]"
        let data = Data(mountsJSON.utf8)
        let mounts = (try? JSONDecoder().decode([WorkspaceDockerMount].self, from: data)) ?? []
        guard !mounts.isEmpty else {
            throw WorkspaceToolError("ASTRA_WORKSPACE_DOCKER_MOUNTS must contain at least the workspace mount")
        }
        let containerEnvironmentJSON = clean(env["ASTRA_WORKSPACE_DOCKER_ENV"]) ?? "{}"
        let containerEnvironmentData = Data(containerEnvironmentJSON.utf8)
        let decodedContainerEnvironment = (try? JSONDecoder().decode([String: String].self, from: containerEnvironmentData)) ?? [:]
        return WorkspaceToolConfiguration(
            dockerExecutable: dockerExecutable,
            image: image,
            containerName: containerName,
            workdir: workdir,
            network: network,
            taskID: taskID,
            runID: runID,
            mounts: mounts,
            containerEnvironment: decodedContainerEnvironment,
            jobRootHostPath: clean(env["ASTRA_WORKSPACE_JOB_ROOT_HOST"]),
            jobRootContainerPath: clean(env["ASTRA_WORKSPACE_JOB_ROOT_CONTAINER"]),
            dockerClientConfigPath: clean(env["DOCKER_CONFIG"]),
            diagnosticsHostPath: clean(env["ASTRA_WORKSPACE_DIAGNOSTICS_HOST"]),
            subagentParentID: clean(env["ASTRA_WORKSPACE_SUBAGENT_PARENT_ID"])
                ?? clean(env["ASTRA_SUBAGENT_PARENT_ID"])
        )
    }

    public func containerCommand(for rawCommand: String) -> WorkspaceCommandPathResolution {
        var command = rawCommand
        var mapped: [WorkspaceCommandPathMapping] = []
        if let ambiguity = firstAmbiguousHostMount(in: command) {
            return WorkspaceCommandPathResolution(
                command: rawCommand,
                mappedPaths: [],
                errorMessage: ambiguousHostMountMessage(ambiguity)
            )
        }
        for mount in mounts.sorted(by: { $0.hostPath.count > $1.hostPath.count }) {
            let hostPath = normalizedMountPath(mount.hostPath)
            let containerPath = normalizedMountPath(mount.containerPath)
            guard hostPath.count > 1, !containerPath.isEmpty, command.contains(hostPath) else {
                continue
            }
            let replacement = replacingMountedHostPath(
                in: command,
                hostPath: hostPath,
                containerPath: containerPath
            )
            command = replacement.command
            if replacement.replaced {
                mapped.append(WorkspaceCommandPathMapping(hostPath: hostPath, containerPath: containerPath))
            }
        }

        if let hostPath = firstUnmappedHostPath(in: command) {
            return WorkspaceCommandPathResolution(
                command: rawCommand,
                mappedPaths: mapped,
                errorMessage: unmappedHostPathMessage(hostPath)
            )
        }

        if let controlPlaneCommand = firstHostControlPlaneCommand(in: command) {
            return WorkspaceCommandPathResolution(
                command: command,
                mappedPaths: mapped,
                errorMessage: hostControlPlaneCommandMessage(controlPlaneCommand)
            )
        }

        return WorkspaceCommandPathResolution(command: command, mappedPaths: mapped, errorMessage: nil)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedContainerEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [String: String]()) { result, pair in
            let (key, value) = pair
            let cleanedKey = cleanEnvironmentKey(key)
            guard !cleanedKey.isEmpty else { return }
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else { return }
            result[cleanedKey] = cleanedValue
        }
    }

    private static func cleanEnvironmentKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }

    private static func defaultContainerPATH(mounts: [WorkspaceDockerMount]) -> String {
        var parts: [String] = []
        for workspaceName in workspacePathNames(mounts: mounts) {
            parts += [
                "/opt/\(workspaceName)/.venv/bin",
                "/opt/\(workspaceName)/venv/bin",
                "/opt/\(workspaceName)/node_modules/.bin"
            ]
        }
        parts += [
            "/opt/project/.venv/bin",
            "/opt/project/venv/bin",
            "/app/.venv/bin",
            "/app/venv/bin",
            "/usr/local/sbin",
            "/usr/local/bin",
            "/usr/sbin",
            "/usr/bin",
            "/sbin",
            "/bin"
        ]
        return deduplicated(parts).joined(separator: ":")
    }

    private static func workspacePathNames(mounts: [WorkspaceDockerMount]) -> [String] {
        deduplicated(mounts.compactMap { mount in
            guard mount.role == "workspace" else { return nil }
            let name = URL(fileURLWithPath: mount.hostPath).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name != ".",
                  name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            return name
        })
    }

    private static func defaultJobRootHostPath(taskID: String, mounts: [WorkspaceDockerMount]) -> String {
        let workspace = mounts.first { $0.role == "workspace" }?.hostPath ?? FileManager.default.temporaryDirectory.path
        return (workspace as NSString).appendingPathComponent(".astra/tasks/\(taskPrefix(taskID))/jobs")
    }

    private static func defaultJobRootContainerPath(taskID: String, mounts: [WorkspaceDockerMount]) -> String {
        let workspace = mounts.first { $0.role == "workspace" }?.containerPath ?? "/workspace"
        return (workspace as NSString).appendingPathComponent(".astra/tasks/\(taskPrefix(taskID))/jobs")
    }

    private static func defaultDockerClientConfigPath(jobRootHostPath: String, runID: String) -> String {
        URL(fileURLWithPath: jobRootHostPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent(".runtime/docker-client/\(taskPrefix(runID))", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func defaultDiagnosticsHostPath(jobRootHostPath: String) -> String {
        URL(fileURLWithPath: jobRootHostPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("diagnostics", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func taskPrefix(_ taskID: String) -> String {
        let cleaned = taskID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String((cleaned.isEmpty ? "unknown" : cleaned).prefix(8))
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func normalizedMountPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return trimmed }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func replacingMountedHostPath(
        in command: String,
        hostPath: String,
        containerPath: String
    ) -> (command: String, replaced: Bool) {
        let escapedHostPath = NSRegularExpression.escapedPattern(for: hostPath)
        let pattern = "(^|[\\s'\"`=:(])(\(escapedHostPath))(?=$|[\\s'\"`;&|),]|/)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (command, false)
        }

        var result = command
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, range: range)
        for match in matches.reversed() where match.numberOfRanges > 2 {
            guard let pathRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            result.replaceSubrange(pathRange, with: containerPath)
        }
        return (result, !matches.isEmpty)
    }

    private func firstAmbiguousHostMount(in command: String) -> WorkspaceAmbiguousMount? {
        let grouped = Dictionary(grouping: mounts) { normalizedMountPath($0.hostPath) }
        for (hostPath, groupedMounts) in grouped where hostPath.count > 1 {
            let containerPaths = Array(Set(groupedMounts.map { normalizedMountPath($0.containerPath) })).sorted()
            guard containerPaths.count > 1,
                  commandContainsMountedHostPath(command, hostPath: hostPath) else {
                continue
            }
            return WorkspaceAmbiguousMount(hostPath: hostPath, containerPaths: containerPaths)
        }
        return nil
    }

    private func commandContainsMountedHostPath(_ command: String, hostPath: String) -> Bool {
        let escapedHostPath = NSRegularExpression.escapedPattern(for: hostPath)
        let pattern = "(^|[\\s'\"`=:(])(\(escapedHostPath))(?=$|[\\s'\"`;&|),]|/)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, range: range) != nil
    }

    private func firstUnmappedHostPath(in command: String) -> String? {
        let pattern = #"(?:^|[\s'"`=:(])(/(?:Users|Volumes|Library|Applications|private/var|var/folders)/[^\s'"`;&|)]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              match.numberOfRanges > 1,
              let pathRange = Range(match.range(at: 1), in: command) else {
            return nil
        }
        return String(command[pathRange])
    }

    private func firstHostControlPlaneCommand(in command: String) -> WorkspaceControlPlaneCommand? {
        let commands = [
            WorkspaceControlPlaneCommand(
                tool: "gh",
                capability: "GitHub",
                subcommands: ["api", "auth", "issue", "pr", "repo", "search"]
            ),
            WorkspaceControlPlaneCommand(
                tool: "jira",
                capability: "Jira"
            ),
            WorkspaceControlPlaneCommand(
                tool: "gcloud",
                capability: "Google Cloud"
            ),
            WorkspaceControlPlaneCommand(
                tool: "bq",
                capability: "BigQuery"
            ),
            WorkspaceControlPlaneCommand(
                tool: "ssh",
                capability: "SSH"
            )
        ]

        return firstHostControlPlaneCommand(in: command, commands: commands, depth: 0)
    }

    private func firstHostControlPlaneCommand(
        in command: String,
        commands: [WorkspaceControlPlaneCommand],
        depth: Int
    ) -> WorkspaceControlPlaneCommand? {
        guard depth < 6 else { return commands.first }

        if let command = firstExecutableHostControlPlaneCommand(in: shellTokens(in: command), commands: commands, depth: depth) {
            return command
        }
        if let command = firstPythonSubprocessControlPlaneCommand(in: command, commands: commands, depth: depth) {
            return command
        }
        for nestedCommand in shellInputScripts(in: command) {
            if let command = firstHostControlPlaneCommand(in: nestedCommand, commands: commands, depth: depth + 1) {
                return command
            }
        }
        for nestedCommand in shellNestedCommands(in: command) {
            if let command = firstHostControlPlaneCommand(in: nestedCommand, commands: commands, depth: depth + 1) {
                return command
            }
        }
        return nil
    }

    private func firstExecutableHostControlPlaneCommand(
        in tokens: [ShellToken],
        commands: [WorkspaceControlPlaneCommand],
        depth: Int
    ) -> WorkspaceControlPlaneCommand? {
        var expectingCommand = true
        var variables: [String: String] = [:]
        var index = tokens.startIndex
        while index < tokens.endIndex {
            switch tokens[index] {
            case .separator:
                expectingCommand = true
            case .word(let word):
                if expectingCommand {
                    if let assignment = shellAssignment(from: word.value),
                       nextNonAssignmentWordIndex(after: index, in: tokens) == nil {
                        variables[assignment.name] = assignment.value
                        index = tokens.index(after: index)
                        continue
                    }
                    if shellReservedWordOpensCommandPosition(word.value) {
                        index = tokens.index(after: index)
                        continue
                    }
                    let commandIndex = normalizedCommandIndex(from: index, in: tokens)
                    if commandIndex != index {
                        index = commandIndex
                        continue
                    }
                    if let shellScript = evalShellScript(at: commandIndex, in: tokens),
                       let command = firstHostControlPlaneCommand(in: shellScript, commands: commands, depth: depth + 1) {
                        return command
                    }
                    if let shellScript = shellRunnerScript(at: commandIndex, in: tokens),
                       let command = firstHostControlPlaneCommand(in: shellScript, commands: commands, depth: depth + 1) {
                        return command
                    }
                    if let command = controlPlaneCommand(at: commandIndex, in: tokens, commands: commands, variables: variables) {
                        return command
                    }
                    expectingCommand = false
                }
            }
            index = tokens.index(after: index)
        }
        return nil
    }

    private func normalizedCommandIndex(from index: Int, in tokens: [ShellToken]) -> Int {
        guard case .word(let word) = tokens[index] else { return index }
        let basename = WorkspaceControlPlaneCommand.normalizedBasename(word.value)
        if isAssignmentWord(word.value) {
            return nextWordIndex(after: index, in: tokens) ?? index
        }
        switch basename {
        case "env":
            return envCommandIndex(after: index, in: tokens) ?? index
        case "command":
            return commandBuiltinTargetIndex(after: index, in: tokens) ?? index
        case "exec":
            return execBuiltinTargetIndex(after: index, in: tokens) ?? index
        default:
            return index
        }
    }

    private func envCommandIndex(after index: Int, in tokens: [ShellToken]) -> Int? {
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if word.value == "--" {
                return nextWordIndex(after: current, in: tokens)
            }
            if word.value == "-S" || word.value == "--split-string" {
                return nextWordIndex(after: current, in: tokens)
            }
            if word.value.hasPrefix("--split-string=") {
                return current
            }
            if envOptionConsumesNextOperand(word.value) {
                cursor = nextWordIndex(after: current, in: tokens).flatMap { nextWordIndex(after: $0, in: tokens) }
                continue
            }
            if word.value.hasPrefix("-") || isAssignmentWord(word.value) {
                cursor = nextWordIndex(after: current, in: tokens)
                continue
            }
            return current
        }
        return nil
    }

    private func envOptionConsumesNextOperand(_ word: String) -> Bool {
        word == "-u" || word == "--unset" || word == "-C" || word == "--chdir"
    }

    private func commandBuiltinTargetIndex(after index: Int, in tokens: [ShellToken]) -> Int? {
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if word.value == "-v" || word.value == "-V" {
                return nil
            }
            if word.value.hasPrefix("-") {
                cursor = nextWordIndex(after: current, in: tokens)
                continue
            }
            return current
        }
        return nil
    }

    private func execBuiltinTargetIndex(after index: Int, in tokens: [ShellToken]) -> Int? {
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if word.value == "-a" {
                cursor = nextWordIndex(after: current, in: tokens).flatMap { nextWordIndex(after: $0, in: tokens) }
                continue
            }
            if word.value.hasPrefix("-") {
                cursor = nextWordIndex(after: current, in: tokens)
                continue
            }
            return current
        }
        return nil
    }

    private func nextWordIndex(after index: Int, in tokens: [ShellToken]) -> Int? {
        let cursor = tokens.index(after: index)
        guard cursor < tokens.endIndex else {
            return nil
        }
        switch tokens[cursor] {
        case .separator:
            return nil
        case .word:
            return cursor
        }
    }

    private func nextNonAssignmentWordIndex(after index: Int, in tokens: [ShellToken]) -> Int? {
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if isAssignmentWord(word.value) {
                cursor = nextWordIndex(after: current, in: tokens)
                continue
            }
            return current
        }
        return nil
    }

    private func shellRunnerScript(at index: Int, in tokens: [ShellToken]) -> String? {
        guard case .word(let command) = tokens[index],
              ["sh", "bash", "zsh"].contains(WorkspaceControlPlaneCommand.normalizedBasename(command.value)) else {
            return nil
        }
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if shellOptionInvokesCommandString(word.value) {
                guard let scriptIndex = nextWordIndex(after: current, in: tokens),
                      case .word(let script) = tokens[scriptIndex] else {
                    return nil
                }
                return script.value
            }
            cursor = nextWordIndex(after: current, in: tokens)
        }
        return nil
    }

    private func evalShellScript(at index: Int, in tokens: [ShellToken]) -> String? {
        guard case .word(let command) = tokens[index],
              WorkspaceControlPlaneCommand.normalizedBasename(command.value) == "eval" else {
            return nil
        }

        var words: [String] = []
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { break }
            words.append(word.value)
            cursor = nextWordIndex(after: current, in: tokens)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private func shellOptionInvokesCommandString(_ word: String) -> Bool {
        if word == "-c" {
            return true
        }
        guard word.hasPrefix("-"), !word.hasPrefix("--") else {
            return false
        }
        return word.dropFirst().contains("c")
    }

    private func controlPlaneCommand(
        at index: Int,
        in tokens: [ShellToken],
        commands: [WorkspaceControlPlaneCommand],
        variables: [String: String] = [:]
    ) -> WorkspaceControlPlaneCommand? {
        guard case .word(let word) = tokens[index],
              let firstWord = resolvedShellWords(word, variables: variables).first,
              let candidate = commands.first(where: { $0.matches(firstWord) }) else {
            return nil
        }
        guard !candidate.subcommands.isEmpty else {
            return candidate
        }
        let resolvedWords = resolvedShellWords(word, variables: variables)
        if resolvedWords.count > 1 {
            return candidate.subcommands.contains(resolvedWords[1].lowercased()) ? candidate : nil
        }
        guard let subcommand = subcommand(after: index, in: tokens, for: candidate) else {
            return nil
        }
        return candidate.subcommands.contains(subcommand.lowercased()) ? candidate : nil
    }

    private func subcommand(after index: Int, in tokens: [ShellToken], for command: WorkspaceControlPlaneCommand) -> String? {
        var cursor = nextWordIndex(after: index, in: tokens)
        while let current = cursor {
            guard case .word(let word) = tokens[current] else { return nil }
            if command.isFlagTakingValue(word.value) {
                cursor = nextWordIndex(after: current, in: tokens).flatMap { nextWordIndex(after: $0, in: tokens) }
                continue
            }
            if word.value.hasPrefix("-") {
                cursor = nextWordIndex(after: current, in: tokens)
                continue
            }
            return word.value
        }
        return nil
    }

    private func firstPythonSubprocessControlPlaneCommand(
        in command: String,
        commands: [WorkspaceControlPlaneCommand],
        depth: Int
    ) -> WorkspaceControlPlaneCommand? {
        for arguments in pythonSubprocessSequenceArguments(in: command) {
            let tokens = arguments.map { ShellToken.word(ShellWord(value: $0)) }
            if let command = firstExecutableHostControlPlaneCommand(in: tokens, commands: commands, depth: depth + 1) {
                return command
            }
        }
        for shellCommand in pythonShellStringCommands(in: command) {
            if let command = firstHostControlPlaneCommand(in: shellCommand, commands: commands, depth: depth + 1) {
                return command
            }
        }
        return nil
    }

    private func shellTokens(in command: String) -> [ShellToken] {
        var tokens: [ShellToken] = []
        var current = ""
        var allowsVariableExpansion = true
        var quote: ShellQuote?
        func finishWord() {
            guard !current.isEmpty else { return }
            tokens.append(.word(ShellWord(value: current, allowsVariableExpansion: allowsVariableExpansion)))
            current.removeAll(keepingCapacity: true)
            allowsVariableExpansion = true
        }

        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let next = command.index(after: index)
            if let activeQuote = quote {
                if activeQuote.matches(character) {
                    quote = nil
                } else if activeQuote != .single, character == "\\", next < command.endIndex {
                    current.append(command[next])
                    if command[next] == "$", current.count == 1 {
                        allowsVariableExpansion = false
                    }
                    index = command.index(after: next)
                    continue
                } else {
                    current.append(character)
                }
                index = next
                continue
            }
            if character == "\\", next < command.endIndex {
                current.append(command[next])
                if command[next] == "$", current.count == 1 {
                    allowsVariableExpansion = false
                }
                index = command.index(after: next)
                continue
            } else if let nextQuote = ShellQuote(character) {
                if nextQuote == .single, current.isEmpty {
                    allowsVariableExpansion = false
                }
                quote = nextQuote
            } else if isShellWordCharacter(character) || character == "=" {
                current.append(character)
            } else {
                finishWord()
                if isShellCommandSeparator(character) {
                    tokens.append(.separator)
                }
            }
            index = next
        }
        finishWord()
        return tokens
    }

    private func shellNestedCommands(in command: String) -> [String] {
        var substitutions: [String] = []
        var quote: ShellQuote?
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let next = command.index(after: index)
            if let activeQuote = quote {
                if character == "\\", activeQuote != .single, next < command.endIndex {
                    index = command.index(after: next)
                    continue
                }
                if activeQuote.matches(character) {
                    quote = nil
                }
                index = next
                continue
            }
            if character == "\\", next < command.endIndex {
                index = command.index(after: next)
                continue
            }
            if let nextQuote = ShellQuote(character) {
                quote = nextQuote
                index = next
                continue
            }
            if character == "$", next < command.endIndex, command[next] == "(" {
                if let extracted = parenthesizedCommand(in: command, start: next) {
                    substitutions.append(extracted.command)
                    index = extracted.end
                    continue
                }
            }
            if (character == "<" || character == ">"), next < command.endIndex, command[next] == "(" {
                if let extracted = parenthesizedCommand(in: command, start: next) {
                    substitutions.append(extracted.command)
                    index = extracted.end
                    continue
                }
            }
            if character == "`", let extracted = backtickCommand(in: command, start: next) {
                substitutions.append(extracted.command)
                index = extracted.end
                continue
            }
            index = next
        }
        return substitutions
    }

    private func shellInputScripts(in command: String) -> [String] {
        pipedShellInputScripts(in: command) + heredocShellInputScripts(in: command)
    }

    private func pipedShellInputScripts(in command: String) -> [String] {
        let pattern = #"(?:^|[;&|]\s*)((?:printf|echo)\s+(?:--\s+)?[\s\S]*?)\s*\|\s*(?:[A-Za-z0-9_./-]*/)?(?:sh|bash|zsh)(?:\s|$)"#
        return captureGroup(1, matchesOf: pattern, in: command).flatMap { quotedStrings(in: $0) }
    }

    private func heredocShellInputScripts(in command: String) -> [String] {
        let pattern = #"(?:^|[;&|]\s*)(?:[A-Za-z0-9_./-]*/)?(?:sh|bash|zsh)\s+<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?[^\n]*\n([\s\S]*?)\n\1(?:\n|$)"#
        return captureGroup(2, matchesOf: pattern, in: command)
    }

    private func pythonSubprocessSequenceArguments(in command: String) -> [[String]] {
        let listPattern = #"subprocess\s*\.\s*(?:run|Popen|call|check_call|check_output)\s*\(\s*\[([^\]]+)\]"#
        let tuplePattern = #"subprocess\s*\.\s*(?:run|Popen|call|check_call|check_output)\s*\(\s*\(([^\)]+)\)"#
        return (captureGroup(1, matchesOf: listPattern, in: command)
            + captureGroup(1, matchesOf: tuplePattern, in: command))
            .map { quotedStrings(in: $0) }
    }

    private func pythonShellStringCommands(in command: String) -> [String] {
        let subprocessPattern = #"subprocess\s*\.\s*(?:run|Popen|call|check_call|check_output)\s*\(\s*(['"])([\s\S]*?)\1[\s\S]*?shell\s*=\s*True"#
        let keywordBeforeShellPattern = #"subprocess\s*\.\s*(?:run|Popen|call|check_call|check_output)\s*\([\s\S]*?args\s*=\s*(['"])([\s\S]*?)\1[\s\S]*?shell\s*=\s*True"#
        let keywordAfterShellPattern = #"subprocess\s*\.\s*(?:run|Popen|call|check_call|check_output)\s*\([\s\S]*?shell\s*=\s*True[\s\S]*?args\s*=\s*(['"])([\s\S]*?)\1"#
        let osSystemPattern = #"os\s*\.\s*system\s*\(\s*(['"])([\s\S]*?)\1"#
        return captureGroup(2, matchesOf: subprocessPattern, in: command)
            + captureGroup(2, matchesOf: keywordBeforeShellPattern, in: command)
            + captureGroup(2, matchesOf: keywordAfterShellPattern, in: command)
            + captureGroup(2, matchesOf: osSystemPattern, in: command)
    }

    private func quotedStrings(in text: String) -> [String] {
        captureGroup(1, matchesOf: #"['"]([^'"]+)['"]"#, in: text)
    }

    private func captureGroup(_ group: Int, matchesOf pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func parenthesizedCommand(in command: String, start: String.Index) -> (command: String, end: String.Index)? {
        var depth = 0
        var quote: ShellQuote?
        var cursor = start
        let contentStart = command.index(after: start)
        while cursor < command.endIndex {
            let character = command[cursor]
            if let activeQuote = quote {
                if activeQuote.matches(character) {
                    quote = nil
                }
            } else if let nextQuote = ShellQuote(character) {
                quote = nextQuote
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (String(command[contentStart..<cursor]), command.index(after: cursor))
                }
            }
            cursor = command.index(after: cursor)
        }
        return nil
    }

    private func backtickCommand(in command: String, start: String.Index) -> (command: String, end: String.Index)? {
        var cursor = start
        while cursor < command.endIndex {
            if command[cursor] == "`" {
                return (String(command[start..<cursor]), command.index(after: cursor))
            }
            cursor = command.index(after: cursor)
        }
        return nil
    }

    private func isShellWordCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "_"
            || character == "-"
            || character == "."
            || character == "/"
            || character == "$"
            || character == "{"
            || character == "}"
    }

    private func isShellCommandSeparator(_ character: Character) -> Bool {
        character == ";" || character == "|" || character == "&" || character == "\n"
    }

    private func shellReservedWordOpensCommandPosition(_ word: String) -> Bool {
        [
            "if", "then", "elif", "else", "while", "until", "do",
            "case", "in", "select", "time", "{", "}"
        ].contains(word)
    }

    private func isAssignmentWord(_ word: String) -> Bool {
        shellAssignment(from: word) != nil
    }

    private func shellAssignment(from word: String) -> (name: String, value: String)? {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
            return nil
        }
        let name = word[..<equals]
        guard name.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "_"
        }) else {
            return nil
        }
        let valueStart = word.index(after: equals)
        return (String(name), String(word[valueStart...]))
    }

    private func resolvedShellWord(_ word: ShellWord, variables: [String: String]) -> String {
        guard word.allowsVariableExpansion,
              let name = shellVariableReferenceName(word.value),
              let value = variables[name] else {
            return word.value
        }
        return value
    }

    private func resolvedShellWords(_ word: ShellWord, variables: [String: String]) -> [String] {
        let resolved = resolvedShellWord(word, variables: variables)
        if resolved == word.value, let splitString = splitEnvString(from: resolved) {
            let fields = shellTokens(in: splitString).compactMap(\.wordValue)
            return fields.isEmpty ? [resolved] : fields
        }
        guard resolved != word.value || resolved.contains(" ") else {
            return [resolved]
        }
        let fields = shellTokens(in: resolved).compactMap(\.wordValue)
        return fields.isEmpty ? [resolved] : fields
    }

    private func splitEnvString(from word: String) -> String? {
        if word.hasPrefix("--split-string=") {
            return String(word.dropFirst("--split-string=".count))
        }
        return nil
    }

    private func shellVariableReferenceName(_ value: String) -> String? {
        if value.hasPrefix("${"), value.hasSuffix("}") {
            let start = value.index(value.startIndex, offsetBy: 2)
            let end = value.index(before: value.endIndex)
            return String(value[start..<end])
        }
        guard value.hasPrefix("$"), value.count > 1 else {
            return nil
        }
        return String(value.dropFirst())
    }

    private func hostControlPlaneCommandMessage(_ command: WorkspaceControlPlaneCommand) -> String {
        [
            "workspace command tried to run the host control-plane CLI '\(command.tool)' inside the Docker workspace.",
            "\(command.capability) metadata and credentials must be handled through ASTRA's host capability layer, not through workspace_shell.",
            "Use workspace_shell only for project commands that belong inside the container image. Enable or repair the \(command.capability) capability if this task needs \(command.capability) access."
        ].joined(separator: "\n")
    }

    private func unmappedHostPathMessage(_ path: String) -> String {
        let mappings = mounts
            .map { "\($0.hostPath) -> \($0.containerPath)" }
            .joined(separator: "; ")
        return [
            "workspace command used a host filesystem path that is not valid inside the Docker workspace: \(path)",
            "Use the container path for mounted workspace files instead.",
            mappings.isEmpty ? nil : "Mounted path mappings: \(mappings)"
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func ambiguousHostMountMessage(_ mount: WorkspaceAmbiguousMount) -> String {
        [
            "workspace command used a host path that maps to more than one Docker container path: \(mount.hostPath)",
            "Use the intended container path explicitly instead of the host path.",
            "Available container paths: \(mount.containerPaths.joined(separator: ", "))"
        ].joined(separator: "\n")
    }
}

private struct WorkspaceControlPlaneCommand {
    var tool: String
    var capability: String
    var subcommands: Set<String> = []

    func matches(_ word: String) -> Bool {
        Self.normalizedBasename(word) == tool
    }

    func isFlagTakingValue(_ word: String) -> Bool {
        guard tool == "gh" else { return false }
        let flags = ["-R", "--repo", "--hostname", "--config", "--jq", "--template"]
        return flags.contains(word)
    }

    static func normalizedBasename(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    }
}

private enum ShellToken {
    case word(ShellWord)
    case separator

    var wordValue: String? {
        switch self {
        case .word(let word):
            return word.value
        case .separator:
            return nil
        }
    }
}

private struct ShellWord {
    var value: String
    var allowsVariableExpansion = true
}

private enum ShellQuote {
    case single
    case double

    init?(_ character: Character) {
        switch character {
        case "'":
            self = .single
        case "\"":
            self = .double
        default:
            return nil
        }
    }

    func matches(_ character: Character) -> Bool {
        switch self {
        case .single:
            return character == "'"
        case .double:
            return character == "\""
        }
    }
}

private struct WorkspaceAmbiguousMount {
    var hostPath: String
    var containerPaths: [String]
}

private enum WorkspaceCommandRoutingPolicy {
    static let maxShortShellSeconds: TimeInterval = 120
    static let maxJobWaitSeconds: TimeInterval = 30

    static func shortShellRejectionMessage(command: String, timeoutSeconds: TimeInterval) -> String? {
        if timeoutSeconds > maxShortShellSeconds {
            return [
                "workspace_shell is limited to short checks of \(Int(maxShortShellSeconds)) seconds or less.",
                "Start long-running workspace work with workspace_job_start, then poll with workspace_job_status, workspace_job_tail, or short workspace_job_wait calls."
            ].joined(separator: "\n")
        }

        if let command = firstLongRunningCommand(in: command) {
            return [
                "workspace_shell received a long-running project command: \(command.displayName).",
                "Use workspace_job_start for builds, tests, dbt runs, migrations, installs, and other commands that may run while the provider is quiet.",
                "Then inspect progress with workspace_job_status and workspace_job_tail."
            ].joined(separator: "\n")
        }
        return nil
    }

    private static func firstLongRunningCommand(in command: String) -> LongRunningCommand? {
        let commands = [
            LongRunningCommand(displayName: "dbt build/run/test/compile", pattern: #"(^|[;&|]\s*)dbt\s+(build|run|test|compile|seed|snapshot)\b"#),
            LongRunningCommand(displayName: "docker build", pattern: #"(^|[;&|]\s*)docker\s+build\b"#),
            LongRunningCommand(displayName: "test suite", pattern: #"(^|[;&|]\s*)(pytest|swift\s+test|xcodebuild\s+test|npm\s+test|pnpm\s+test|yarn\s+test)\b"#),
            LongRunningCommand(displayName: "dependency install", pattern: #"(^|[;&|]\s*)(npm|pnpm|yarn)\s+(install|ci)\b"#),
            LongRunningCommand(displayName: "migration or deployment", pattern: #"(^|[;&|]\s*)(alembic|rails|django-admin|python\s+manage\.py)\s+(upgrade|migrate|migration|deploy)\b"#)
        ]
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return commands.first { candidate in
            guard let regex = try? NSRegularExpression(pattern: candidate.pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: command, range: range) != nil
        }
    }

    private struct LongRunningCommand {
        var displayName: String
        var pattern: String
    }
}

public struct WorkspaceCommandPathMapping: Equatable, Sendable {
    public var hostPath: String
    public var containerPath: String
}

public struct WorkspaceCommandPathResolution: Equatable, Sendable {
    public var command: String
    public var mappedPaths: [WorkspaceCommandPathMapping]
    public var errorMessage: String?
}

public struct WorkspaceCommandResult: Equatable, Sendable {
    public var command: String
    public var routedCommand: String?
    public var workingDirectory: String?
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(
        command: String,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        routedCommand: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.routedCommand = routedCommand
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol WorkspaceCommandExecutor: AnyObject {
    func run(command: String, timeoutSeconds: TimeInterval) -> WorkspaceCommandResult
    func cleanup()
}

public final class DockerWorkspaceCommandExecutor: WorkspaceCommandExecutor {
    private let configuration: WorkspaceToolConfiguration
    private var containerStarted = false

    public init(configuration: WorkspaceToolConfiguration) {
        self.configuration = configuration
    }

    public func run(command: String, timeoutSeconds: TimeInterval) -> WorkspaceCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorkspaceCommandResult(
                command: command,
                exitCode: 2,
                stdout: "",
                stderr: "workspace_shell requires a non-empty command",
                workingDirectory: configuration.workdir
            )
        }
        if let message = WorkspaceCommandRoutingPolicy.shortShellRejectionMessage(
            command: trimmed,
            timeoutSeconds: timeoutSeconds
        ) {
            return WorkspaceCommandResult(
                command: command,
                exitCode: 2,
                stdout: "",
                stderr: message,
                workingDirectory: configuration.workdir
            )
        }
        let pathResolution = configuration.containerCommand(for: trimmed)
        if let errorMessage = pathResolution.errorMessage {
            return WorkspaceCommandResult(
                command: command,
                exitCode: 2,
                stdout: "",
                stderr: errorMessage,
                routedCommand: pathResolution.command,
                workingDirectory: configuration.workdir
            )
        }
        let start = ensureContainerStarted()
        guard start.exitCode == 0 else {
            return WorkspaceCommandResult(
                command: command,
                exitCode: start.exitCode,
                stdout: start.stdout,
                stderr: start.stderr.isEmpty ? "Failed to start Docker workspace container" : start.stderr,
                timedOut: start.timedOut,
                routedCommand: pathResolution.command,
                workingDirectory: configuration.workdir
            )
        }
        var result = runDockerCommand(
            arguments: ["exec", "-i", "--workdir", configuration.workdir, configuration.containerName, "sh", "-c", pathResolution.command],
            commandLabel: command,
            timeoutSeconds: timeoutSeconds
        )
        result.routedCommand = pathResolution.command
        result.workingDirectory = configuration.workdir
        return result
    }

    public func cleanup() {
        guard containerStarted else { return }
        _ = runDockerCommand(arguments: ["stop", configuration.containerName], commandLabel: "docker stop", timeoutSeconds: 10)
        containerStarted = false
    }

    public func ensureContainerStarted() -> WorkspaceCommandResult {
        let inspect = runDockerCommand(
            arguments: ["inspect", "-f", "{{.State.Running}}", configuration.containerName],
            commandLabel: "docker inspect",
            timeoutSeconds: 5
        )
        if inspect.exitCode == 0,
           inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            containerStarted = true
            return inspect
        }
        containerStarted = false

        _ = runDockerCommand(arguments: ["rm", "-f", configuration.containerName], commandLabel: "docker rm", timeoutSeconds: 10)

        var args = [
            "run", "--rm", "-d",
            "--name", configuration.containerName,
            "--label", "com.coral.astra.workspace_executor=true",
            "--label", "com.coral.astra.task=\(configuration.taskID)",
            "--label", "com.coral.astra.run=\(configuration.runID)",
            "--workdir", configuration.workdir,
            "--network", configuration.network
        ]
        for mount in configuration.mounts {
            args += ["--volume", "\(mount.hostPath):\(mount.containerPath):\(mount.access)"]
        }
        for key in configuration.containerEnvironment.keys.sorted() {
            if key == "PATH", let value = configuration.containerEnvironment[key] {
                args += ["--env", "\(key)=\(value)"]
            } else {
                args += ["--env", key]
            }
        }
        args += [configuration.image, "sh", "-c", "while :; do sleep 3600; done"]

        let result = runDockerCommand(
            arguments: args,
            commandLabel: "docker run",
            timeoutSeconds: 30,
            environment: dockerClientEnvironment(configuration.containerEnvironment)
        )
        if result.exitCode == 0 {
            containerStarted = true
        }
        return result
    }

    public func runDockerCommand(
        arguments: [String],
        commandLabel: String,
        timeoutSeconds: TimeInterval,
        environment: [String: String] = [:]
    ) -> WorkspaceCommandResult {
        let invocation = dockerInvocation(arguments)
        return ProcessRunner.run(
            executablePath: invocation.executablePath,
            arguments: invocation.arguments,
            commandLabel: commandLabel,
            timeoutSeconds: timeoutSeconds,
            environment: dockerClientEnvironment(environment)
        )
    }

    private func dockerInvocation(_ arguments: [String]) -> DockerProcessInvocation {
        DockerProcessInvocation.resolve(
            dockerExecutable: configuration.dockerExecutable,
            arguments: arguments
        )
    }
}

struct DockerProcessInvocation: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]

    static func resolve(dockerExecutable: String, arguments: [String]) -> DockerProcessInvocation {
        if dockerExecutable.hasPrefix("/") {
            return DockerProcessInvocation(executablePath: dockerExecutable, arguments: arguments)
        }
        return DockerProcessInvocation(executablePath: "/usr/bin/env", arguments: [dockerExecutable] + arguments)
    }
}

extension DockerWorkspaceCommandExecutor {
    private func dockerClientEnvironment(_ environment: [String: String]) -> [String: String] {
        var dockerEnvironment = environment.filter { key, _ in key != "PATH" }
        prepareDockerClientConfigDirectory()
        dockerEnvironment["DOCKER_CONFIG"] = configuration.dockerClientConfigPath
        return dockerEnvironment
    }

    private func prepareDockerClientConfigDirectory() {
        let directory = URL(fileURLWithPath: configuration.dockerClientConfigPath, isDirectory: true)
        let config = directory.appendingPathComponent("config.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: config.path) {
                try #"{"auths":{}}"#
                    .appending("\n")
                    .write(to: config, atomically: true, encoding: .utf8)
            }
        } catch {
            // Keep the MCP helper non-throwing. Docker will still surface a
            // usable error if it cannot read the prepared client config.
        }
    }
}

public final class WorkspaceToolDiagnosticsRecorder: @unchecked Sendable {
    private let diagnosticsDirectory: URL
    private let fileURL: URL
    private let taskID: String
    private let runID: String
    private let route: String
    private let subagentParentID: String?
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(configuration: WorkspaceToolConfiguration, fileManager: FileManager = .default) {
        self.diagnosticsDirectory = URL(fileURLWithPath: configuration.diagnosticsHostPath, isDirectory: true)
        self.fileURL = diagnosticsDirectory.appendingPathComponent("workspace_tool_activity.jsonl", isDirectory: false)
        self.taskID = configuration.taskID
        self.runID = configuration.runID
        self.route = "docker_workspace_mcp"
        self.subagentParentID = configuration.subagentParentID
        self.fileManager = fileManager
    }

    func recordShell(
        toolName: String,
        command: String,
        mappedCommand: String?,
        workingDirectory: String?,
        timeoutSeconds: TimeInterval,
        result: WorkspaceCommandResult
    ) {
        write(WorkspaceToolDiagnosticRecord(
            timestamp: Self.timestamp(),
            taskID: taskID,
            runID: runID,
            route: route,
            toolName: toolName,
            command: command,
            mappedCommand: mappedCommand,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stderrTail: Self.tail(result.stderr),
            jobID: nil,
            jobStatus: nil,
            heartbeatPath: nil,
            subagentParentID: subagentParentID
        ))
    }

    func recordJob(
        toolName: String,
        command: String?,
        job: WorkspaceManagedJobRecord,
        timeoutSeconds: TimeInterval? = nil
    ) {
        write(WorkspaceToolDiagnosticRecord(
            timestamp: Self.timestamp(),
            taskID: taskID,
            runID: runID,
            route: route,
            toolName: toolName,
            command: command,
            mappedCommand: job.command,
            workingDirectory: nil,
            timeoutSeconds: timeoutSeconds ?? job.timeoutSeconds,
            exitCode: job.exitCode,
            timedOut: job.status == .timedOut,
            stderrTail: Self.tail(job.message ?? ""),
            jobID: job.jobID,
            jobStatus: job.status.rawValue,
            heartbeatPath: job.heartbeatPath.isEmpty ? nil : job.heartbeatPath,
            subagentParentID: subagentParentID
        ))
    }

    func recordTail(toolName: String, jobID: String, stream: String, lines: Int) {
        write(WorkspaceToolDiagnosticRecord(
            timestamp: Self.timestamp(),
            taskID: taskID,
            runID: runID,
            route: route,
            toolName: toolName,
            command: nil,
            mappedCommand: nil,
            workingDirectory: nil,
            timeoutSeconds: nil,
            exitCode: nil,
            timedOut: false,
            stderrTail: nil,
            jobID: jobID,
            jobStatus: "tail:\(stream):\(lines)",
            heartbeatPath: nil,
            subagentParentID: subagentParentID
        ))
    }

    private func write(_ record: WorkspaceToolDiagnosticRecord) {
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics should never make the workspace tool fail. The
            // provider-facing command result remains the source of truth.
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func tail(_ value: String, limit: Int = 2_000) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(limit))
    }
}

private struct WorkspaceToolDiagnosticRecord: Codable {
    var timestamp: String
    var taskID: String
    var runID: String
    var route: String
    var toolName: String
    var command: String?
    var mappedCommand: String?
    var workingDirectory: String?
    var timeoutSeconds: TimeInterval?
    var exitCode: Int32?
    var timedOut: Bool
    var stderrTail: String?
    var jobID: String?
    var jobStatus: String?
    var heartbeatPath: String?
    var subagentParentID: String?
}

public final class WorkspaceMCPServer {
    private let executor: WorkspaceCommandExecutor
    private let jobManager: WorkspaceJobManaging?
    private let diagnosticsRecorder: WorkspaceToolDiagnosticsRecorder?

    public init(
        executor: WorkspaceCommandExecutor,
        jobManager: WorkspaceJobManaging? = nil,
        diagnosticsRecorder: WorkspaceToolDiagnosticsRecorder? = nil
    ) {
        self.executor = executor
        self.jobManager = jobManager
        self.diagnosticsRecorder = diagnosticsRecorder
    }

    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String else {
            return encodeError(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        }

        let id = object["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }
        switch method {
        case "initialize":
            return encodeResult(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "astra-workspace", "version": "1.0.0"]
            ])
        case "tools/list":
            return encodeResult(id: id, result: [
                "tools": toolSchemas()
            ])
        case "tools/call":
            return handleToolCall(id: id, object: object)
        default:
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    public func cleanup() {
        executor.cleanup()
    }

    private func handleToolCall(id: Any?, object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch toolName {
        case "workspace_shell":
            return handleWorkspaceShell(id: id, arguments: arguments)
        case "workspace_job_start":
            return handleWorkspaceJobStart(id: id, arguments: arguments)
        case "workspace_job_status":
            return handleWorkspaceJobStatus(id: id, arguments: arguments)
        case "workspace_job_tail":
            return handleWorkspaceJobTail(id: id, arguments: arguments)
        case "workspace_job_cancel":
            return handleWorkspaceJobCancel(id: id, arguments: arguments)
        case "workspace_job_wait":
            return handleWorkspaceJobWait(id: id, arguments: arguments)
        default:
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
    }

    private func handleWorkspaceShell(id: Any?, arguments: [String: Any]) -> String? {
        guard let command = arguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeError(id: id, code: -32602, message: "workspace_shell requires command")
        }
        let timeout = timeoutSeconds(from: arguments["timeout_seconds"]) ?? 120
        let result = executor.run(command: command, timeoutSeconds: timeout)
        diagnosticsRecorder?.recordShell(
            toolName: "workspace_shell",
            command: command,
            mappedCommand: result.routedCommand,
            workingDirectory: result.workingDirectory,
            timeoutSeconds: timeout,
            result: result
        )
        return encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(result)
            ]],
            "isError": result.exitCode != 0 || result.timedOut
        ])
    }

    private func handleWorkspaceJobStart(id: Any?, arguments: [String: Any]) -> String? {
        guard let jobManager else {
            return encodeError(id: id, code: -32001, message: "workspace_job_start is unavailable")
        }
        guard let command = arguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeError(id: id, code: -32602, message: "workspace_job_start requires command")
        }
        let job = jobManager.start(
            command: command,
            timeoutSeconds: timeoutSeconds(from: arguments["timeout_seconds"]),
            label: clean(arguments["label"] as? String),
            progressProbe: clean(arguments["progress_probe"] as? String)
        )
        diagnosticsRecorder?.recordJob(toolName: "workspace_job_start", command: command, job: job)
        return encodeJobResult(id: id, job: job)
    }

    private func handleWorkspaceJobStatus(id: Any?, arguments: [String: Any]) -> String? {
        guard let jobManager else {
            return encodeError(id: id, code: -32001, message: "workspace_job_status is unavailable")
        }
        guard let jobID = clean(arguments["job_id"] as? String) else {
            return encodeError(id: id, code: -32602, message: "workspace_job_status requires job_id")
        }
        let job = jobManager.status(jobID: jobID)
        diagnosticsRecorder?.recordJob(toolName: "workspace_job_status", command: nil, job: job)
        return encodeJobResult(id: id, job: job)
    }

    private func handleWorkspaceJobTail(id: Any?, arguments: [String: Any]) -> String? {
        guard let jobManager else {
            return encodeError(id: id, code: -32001, message: "workspace_job_tail is unavailable")
        }
        guard let jobID = clean(arguments["job_id"] as? String) else {
            return encodeError(id: id, code: -32602, message: "workspace_job_tail requires job_id")
        }
        let stream = clean(arguments["stream"] as? String) ?? "stdout"
        let lines = intValue(from: arguments["lines"]) ?? 120
        let tail = jobManager.tail(jobID: jobID, stream: stream, lines: lines)
        diagnosticsRecorder?.recordTail(toolName: "workspace_job_tail", jobID: jobID, stream: stream, lines: lines)
        return encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(tail)
            ]],
            "isError": false
        ])
    }

    private func handleWorkspaceJobCancel(id: Any?, arguments: [String: Any]) -> String? {
        guard let jobManager else {
            return encodeError(id: id, code: -32001, message: "workspace_job_cancel is unavailable")
        }
        guard let jobID = clean(arguments["job_id"] as? String) else {
            return encodeError(id: id, code: -32602, message: "workspace_job_cancel requires job_id")
        }
        let job = jobManager.cancel(jobID: jobID)
        diagnosticsRecorder?.recordJob(toolName: "workspace_job_cancel", command: nil, job: job)
        return encodeJobResult(id: id, job: job)
    }

    private func handleWorkspaceJobWait(id: Any?, arguments: [String: Any]) -> String? {
        guard let jobManager else {
            return encodeError(id: id, code: -32001, message: "workspace_job_wait is unavailable")
        }
        guard let jobID = clean(arguments["job_id"] as? String) else {
            return encodeError(id: id, code: -32602, message: "workspace_job_wait requires job_id")
        }
        let timeout = min(timeoutSeconds(from: arguments["max_wait_seconds"]) ?? 30, WorkspaceCommandRoutingPolicy.maxJobWaitSeconds)
        let job = jobManager.wait(jobID: jobID, timeoutSeconds: timeout)
        diagnosticsRecorder?.recordJob(toolName: "workspace_job_wait", command: nil, job: job, timeoutSeconds: timeout)
        return encodeJobResult(id: id, job: job)
    }

    private func timeoutSeconds(from value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber:
            return max(1, number.doubleValue)
        case let value as String:
            return Double(value).map { max(1, $0) }
        default:
            return nil
        }
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return max(1, number.intValue)
        case let value as String:
            return Int(value).map { max(1, $0) }
        default:
            return nil
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func encodeJobResult(id: Any?, job: WorkspaceManagedJobRecord) -> String? {
        encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": formatted(job)
            ]],
            "isError": job.status == .failed || job.status == .timedOut
        ])
    }

    private func formatted(_ result: WorkspaceCommandResult) -> String {
        var lines = [
            "command: \(result.command)",
            "exit_code: \(result.exitCode)"
        ]
        if result.timedOut {
            lines.append("timed_out: true")
        }
        lines += [
            "stdout:",
            result.stdout.isEmpty ? "<empty>" : result.stdout,
            "stderr:",
            result.stderr.isEmpty ? "<empty>" : result.stderr
        ]
        return lines.joined(separator: "\n")
    }

    private func formatted(_ job: WorkspaceManagedJobRecord) -> String {
        var lines = [
            "job_id: \(job.jobID)",
            "status: \(job.status.rawValue)",
            "runtime: \(job.runtime)",
            "command: \(job.command)"
        ]
        if let label = job.label {
            lines.append("label: \(label)")
        }
        if let progressProbe = job.progressProbe {
            lines.append("progress_probe: \(progressProbe)")
        }
        if let exitCode = job.exitCode {
            lines.append("exit_code: \(exitCode)")
        }
        if let lastHeartbeatAt = job.lastHeartbeatAt {
            lines.append("last_heartbeat_at: \(iso8601(lastHeartbeatAt))")
        }
        if let lastOutputAt = job.lastOutputAt {
            lines.append("last_output_at: \(iso8601(lastOutputAt))")
        }
        if let completedAt = job.completedAt {
            lines.append("completed_at: \(iso8601(completedAt))")
        }
        if let message = job.message {
            lines.append("message: \(message)")
        }
        lines += [
            "stdout_log: \(job.stdoutLogPath.isEmpty ? "<unavailable>" : job.stdoutLogPath)",
            "stderr_log: \(job.stderrLogPath.isEmpty ? "<unavailable>" : job.stderrLogPath)",
            "heartbeat: \(job.heartbeatPath.isEmpty ? "<unavailable>" : job.heartbeatPath)",
            "result: \(job.resultPath.isEmpty ? "<unavailable>" : job.resultPath)"
        ]
        return lines.joined(separator: "\n")
    }

    private func formatted(_ tail: WorkspaceManagedJobTail) -> String {
        [
            "job_id: \(tail.jobID)",
            "stream: \(tail.stream)",
            tail.text.isEmpty ? "<empty>" : tail.text
        ].joined(separator: "\n")
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func toolSchemas() -> [[String: Any]] {
        [
            workspaceShellSchema(),
            workspaceJobStartSchema(),
            workspaceJobStatusSchema(),
            workspaceJobTailSchema(),
            workspaceJobCancelSchema(),
            workspaceJobWaitSchema()
        ]
    }

    private func workspaceShellSchema() -> [String: Any] {
        [
            "name": "workspace_shell",
            "description": "Run a short shell command inside the ASTRA-managed Docker workspace container using the image environment. Use workspace_job_start for long-running commands.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "Shell command to run from the container workspace directory."
                    ],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Optional command timeout. Defaults to 120 seconds."
                    ]
                ],
                "required": ["command"],
                "additionalProperties": false
            ]
        ]
    }

    private func workspaceJobStartSchema() -> [String: Any] {
        [
            "name": "workspace_job_start",
            "description": "Start a durable long-running workspace command inside the ASTRA-managed Docker container and return immediately with a job id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Shell command to run inside the workspace container."],
                    "timeout_seconds": ["type": "number", "description": "Optional job timeout hint recorded with the job."],
                    "label": ["type": "string", "description": "Optional short human-readable job label."],
                    "progress_probe": ["type": "string", "description": "Optional progress probe name such as dbt, pytest, docker-build, or generic-log."]
                ],
                "required": ["command"],
                "additionalProperties": false
            ]
        ]
    }

    private func workspaceJobStatusSchema() -> [String: Any] {
        [
            "name": "workspace_job_status",
            "description": "Read the durable status and heartbeat for a workspace job.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string", "description": "Job id returned by workspace_job_start."]
                ],
                "required": ["job_id"],
                "additionalProperties": false
            ]
        ]
    }

    private func workspaceJobTailSchema() -> [String: Any] {
        [
            "name": "workspace_job_tail",
            "description": "Read recent stdout or stderr lines for a workspace job.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string", "description": "Job id returned by workspace_job_start."],
                    "stream": ["type": "string", "description": "stdout or stderr. Defaults to stdout."],
                    "lines": ["type": "number", "description": "Maximum recent lines to return. Defaults to 120."]
                ],
                "required": ["job_id"],
                "additionalProperties": false
            ]
        ]
    }

    private func workspaceJobCancelSchema() -> [String: Any] {
        [
            "name": "workspace_job_cancel",
            "description": "Ask ASTRA to terminate a running workspace job.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string", "description": "Job id returned by workspace_job_start."]
                ],
                "required": ["job_id"],
                "additionalProperties": false
            ]
        ]
    }

    private func workspaceJobWaitSchema() -> [String: Any] {
        [
            "name": "workspace_job_wait",
            "description": "Wait briefly for a workspace job to reach a terminal state, without holding the provider for the full job duration.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string", "description": "Job id returned by workspace_job_start."],
                    "max_wait_seconds": ["type": "number", "description": "Maximum wait time for this polling call. Defaults to 30 seconds."]
                ],
                "required": ["job_id"],
                "additionalProperties": false
            ]
        ]
    }

    private func encodeResult(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": normalizedID(id), "result": result])
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String? {
        encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "error": ["code": code, "message": message]
        ])
    }

    private func normalizedID(_ id: Any?) -> Any {
        switch id {
        case let value as String: return value
        case let value as NSNumber: return value
        case .none: return NSNull()
        default: return NSNull()
        }
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public enum AstraWorkspaceToolMain {
    public static func run() {
        do {
            let configuration = try WorkspaceToolConfiguration.fromEnvironment()
            let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
            let jobManager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)
            let recorder = WorkspaceToolDiagnosticsRecorder(configuration: configuration)
            let server = WorkspaceMCPServer(
                executor: executor,
                jobManager: jobManager,
                diagnosticsRecorder: recorder
            )
            defer { server.cleanup() }
            while let line = readLine() {
                if let response = server.handleLine(line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        } catch {
            let server = WorkspaceMCPServer(executor: FailingWorkspaceCommandExecutor(message: error.localizedDescription))
            while let line = readLine() {
                if let response = server.handleLine(line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
        }
    }
}

private final class FailingWorkspaceCommandExecutor: WorkspaceCommandExecutor {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func run(command: String, timeoutSeconds _: TimeInterval) -> WorkspaceCommandResult {
        WorkspaceCommandResult(command: command, exitCode: 2, stdout: "", stderr: message)
    }

    func cleanup() {}
}

public struct WorkspaceToolError: LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private enum ProcessRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        commandLabel: String,
        timeoutSeconds: TimeInterval,
        environment: [String: String] = [:]
    ) -> WorkspaceCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBuffer.append(data) }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return WorkspaceCommandResult(
                command: commandLabel,
                exitCode: 127,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())

        return WorkspaceCommandResult(
            command: commandLabel,
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue,
            timedOut: timedOut
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? String(decoding: snapshot, as: UTF8.self)
    }
}
