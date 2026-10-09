import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// What an Auto run's agent did outside the machine with its own tools.
///
/// In Auto the agent holds native Git and GitHub credentials and can push,
/// open a pull request, or comment with `gh` itself; ASTRA never sees those as
/// typed actions with receipts. This reads the run's own tool calls at the run
/// boundary and records each successful one that is not known local work —
/// what Ask would have asked about — so the chat says what was run on the
/// user's behalf, with the link the command printed.
///
/// A record, never a gate: it names the programs the command ran, gives a
/// recognised `git push` or `gh` write its own title only when the call was
/// that one command and succeeded, and says when a call failed. Nothing about whether the command was allowed depends on it.
@MainActor
enum AgentExternalActionObserver {
    nonisolated static let eventType = "external.action.observed"
    /// The successful result of a call that ran a recognised external action,
    /// named by that call's evidence (the `tool.use` payload). Not shown in
    /// the thread; it is what pairs a result with its own call.
    nonisolated static let resultEventType = "external.action.result"

    struct ResultMarker: Codable, Equatable, Sendable {
        var version = 1
        /// The `tool.use` payload, truncated as the event is: what pairs it.
        let toolUseEvidence: String
        /// The receipt the record reads (`receipt(in:host:)`); older markers
        /// hold the result's first 4,000 characters.
        let output: String
        /// The whole command; only in markers written before `verdict`, which
        /// replaced it so that the part of a command past the event's cut —
        /// where a header or token can sit — is never stored.
        var command: String?
        /// The call came back as an error; nil in older markers, which were
        /// written only for successes.
        var failed: Bool?
        /// What the whole command was judged to be when the call was recorded.
        var verdict: Verdict?
    }

    /// The judgment of a call's whole command, kept instead of the command:
    /// only the action, the names of the programs it ran, and the scheme and
    /// host it named.
    struct Verdict: Codable, Equatable, Sendable {
        /// `push`, `pullRequest:<verb>`, `issue:<verb>`, `release`,
        /// `api:<METHOD>`, or `command`.
        var action: String
        var names: String
        var webHost: String?
        var gitHubURL: String?
        var enterpriseHost: String?
        var enterpriseRepository: String?
    }

    nonisolated static func resultMarker(
        evidence: String, fullEvidence: String? = nil, output: String, failed: Bool = false
    ) -> ResultMarker? {
        guard let command = shellCommandText(fromToolUsePayload: fullEvidence ?? evidence),
              let verdict = verdict(for: command) else { return nil }
        return ResultMarker(toolUseEvidence: evidence, output: receipt(in: output, host: verdict.enterpriseHost),
                            failed: failed ? true : nil, verdict: verdict)
    }

    /// What the record reads from a result, taken from all of it: the first
    /// GitHub link and the first `To <remote>` line `git push` prints, which
    /// can follow any amount of hook output.
    nonisolated static func receipt(in output: String, host: String?) -> String {
        var lines: [String] = []
        if let url = firstGitHubURL(in: output, host: host) { lines.append(url) }
        if let remote = output.range(of: #"(?m)^To\s+\S+"#, options: .regularExpression) {
            lines.append(String(output[remote].prefix(1_000)))
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func verdict(for command: String) -> Verdict? {
        let text = ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))
        let enterprise = enterpriseGitHub(in: command)
        if let action = recordedAction(in: command) {
            return Verdict(action: encode(action), names: commandNames(text), webHost: firstWebURL(in: text),
                           gitHubURL: firstGitHubURL(in: text, host: enterprise?.host),
                           enterpriseHost: enterprise?.host, enterpriseRepository: enterprise?.repository)
        }
        return nil
    }

    nonisolated static func encode(_ action: Action) -> String {
        switch action {
        case .push: return "push"
        case .pullRequest(let verb): return "pullRequest:\(verb)"
        case .issue(let verb): return "issue:\(verb)"
        case .release: return "release"
        case .api(let method): return "api:\(method)"
        case .command: return "command"
        }
    }

    /// The recognised action a verdict names; nil for a plain command.
    nonisolated static func decodeAction(_ value: String) -> Action? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "push": return .push
        case "release": return .release
        case "pullRequest" where parts.count == 2: return .pullRequest(verb: parts[1])
        case "issue" where parts.count == 2: return .issue(verb: parts[1])
        case "api" where parts.count == 2: return .api(method: parts[1])
        default: return nil
        }
    }

    struct Observation: Codable, Equatable, Sendable {
        var version = 1
        /// The `tool.use` event the record was read from, so a second pass over
        /// the same run records nothing new.
        let sourceEventID: UUID
        let title: String
        let destination: String
        let url: String?
    }

    @discardableResult
    static func recordObservedActions(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        policyLevel: AgentPolicyLevel
    ) -> [Observation] {
        guard !ExternalActionPolicy.asksUser(for: .agentCommand, level: policyLevel) else { return [] }
        let runEvents = task.events
            .filter { $0.run?.id == run.id }
            .sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
        let alreadyRecorded = Set(runEvents.compactMap { event -> UUID? in
            guard event.type == eventType, let data = event.payload.data(using: .utf8) else { return nil }
            return (try? TaskEventPayloadCodec.makeDecoder().decode(Observation.self, from: data))?.sourceEventID
        })
        // A run recorded with result markers pairs each call with its own
        // successful result, in order for repeated identical calls; an older
        // run falls back to reading the results that follow the call.
        var markers = runEvents.compactMap { event -> ResultMarker? in
            guard event.type == resultEventType, let data = event.payload.data(using: .utf8) else { return nil }
            return try? TaskEventPayloadCodec.makeDecoder().decode(ResultMarker.self, from: data)
        }
        let pairsByMarker = !markers.isEmpty
        var observations: [Observation] = []
        for (index, event) in runEvents.enumerated()
        where event.type == TaskEventTypes.Tool.use.rawValue && !alreadyRecorded.contains(event.id) {
            guard let truncated = shellCommandText(fromToolUsePayload: event.payload) else { continue }
            let command: String
            let output: String
            let failed: Bool
            if pairsByMarker {
                guard let position = markers.firstIndex(where: { $0.toolUseEvidence == event.payload }) else { continue }
                let marker = markers.remove(at: position)
                // A marker with a verdict is itself the record
                // (`ObservedExternalActionRecordSource`), durable from the
                // moment the result arrived; nothing is written here for it.
                if marker.verdict != nil { continue }
                command = marker.command ?? truncated
                output = marker.output
                failed = marker.failed == true
            } else {
                guard let fallback = fallbackResult(after: index, call: event, in: runEvents) else { continue }
                command = truncated
                output = fallback.output
                failed = fallback.failed
            }
            guard let recognised = recordedAction(in: command) else { continue }
            // A call that came back as an error may still have acted partway
            // (`curl -d … ; false`), so it is recorded too, as the command it
            // ran and that it failed, never as the action it was trying.
            let action = failed ? Action.command(command) : recognised
            let actions = [action]
            let enterprise = enterpriseGitHub(in: command)
            var urls = actionURLs(for: actions, output: output, command: command, host: enterprise?.host)
            // An SSH push prints `To git@github.com:owner/repo.git`, no web address.
            if action == .push, urls.first == .some(nil), let repository = pushGitHubRepository(in: output) {
                urls = ["https://github.com/\(repository)"]
            }
            for (action, url) in zip(actions, urls) {
                let observation = Observation(
                    sourceEventID: event.id,
                    title: failed ? "Ran \(commandNames(command)), which exited with an error" : title(for: action, url: url),
                    destination: destination(for: action, url: url, result: output, enterprise: enterprise),
                    url: url
                )
                modelContext.insert(TaskEvent.structuredPayloadEvent(
                    task: task,
                    type: eventType,
                    payload: observation,
                    run: run
                ))
                observations.append(observation)
            }
        }
        return observations
    }

    /// The record of a call judged when it was recorded (`Verdict`).
    static func observation(
        of verdict: Verdict, event: TaskEvent, output: String, failed: Bool
    ) -> Observation? {
        observation(of: verdict, sourceEventID: event.id, output: output, failed: failed)
    }

    nonisolated static func observation(
        of verdict: Verdict, sourceEventID: UUID, output: String, failed: Bool
    ) -> Observation? {
        // A failed call is recorded as the programs it ran, never as the
        // action it was trying.
        let action = failed ? nil : decodeAction(verdict.action)
        let enterprise = verdict.enterpriseHost.map { (host: $0, repository: verdict.enterpriseRepository) }
        var url = firstGitHubURL(in: output, host: enterprise?.host) ?? verdict.gitHubURL
        if action == .push, url == nil, let repository = pushGitHubRepository(in: output) {
            url = "https://github.com/\(repository)"
        }
        guard let action else {
            let link = url ?? verdict.webHost
            return Observation(
                sourceEventID: sourceEventID,
                title: "Ran \(verdict.names)" + (failed ? ", which exited with an error" : ""),
                destination: link.flatMap { URLComponents(string: $0)?.host }
                    ?? verdict.names.split(separator: "`").first.map { String($0.split(separator: " ").first ?? $0) }
                    ?? "Command",
                url: link
            )
        }
        return Observation(
            sourceEventID: sourceEventID,
            title: title(for: action, url: url),
            destination: destination(for: action, url: url, result: output, enterprise: enterprise),
            url: url
        )
    }

    /// One link per action. A single action takes the first link printed; in
    /// a compound call each takes the first unused link of its own kind (a
    /// pull request's `/pull/`, an issue's `/issues/`), and an action with
    /// none gets no link rather than another action's.
    static func actionURLs(for actions: [Action], output: String, command: String, host: String?) -> [String?] {
        guard actions.count > 1 else {
            let github = firstGitHubURL(in: output, host: host) ?? firstGitHubURL(in: command, host: host)
            // Any other command links where it went: the first web address it names.
            if case .command = actions.first { return [github ?? firstWebURL(in: command)] }
            return [github]
        }
        var available = allGitHubURLs(in: output, host: host)
        return actions.map { action in
            let marker: String
            switch action {
            case .pullRequest: marker = "/pull/"
            case .issue: marker = "/issues/"
            case .release: marker = "/releases/"
            default: return nil
            }
            guard let index = available.firstIndex(where: { $0.contains(marker) }) else { return nil }
            return available.remove(at: index)
        }
    }

    static func allGitHubURLs(in text: String, host: String? = nil) -> [String] {
        var urls: [String] = []
        var rest = Substring(text)
        while let url = firstGitHubURL(in: String(rest), host: host), let range = rest.range(of: url) {
            urls.append(url)
            rest = rest[range.upperBound...]
        }
        return urls
    }

    /// For runs recorded before result markers: the first result after the
    /// call that is not known to be another call's, and whether it failed.
    private static func fallbackResult(
        after index: Int, call event: TaskEvent, in runEvents: [TaskEvent]
    ) -> (output: String, failed: Bool)? {
        // A failed result names the call it belongs to (a batch can answer
        // another call first); a successful one does not, so the first result
        // not known to be someone else's decides, and a missing result is not
        // evidence of anything.
        let later = runEvents[(index + 1)...]
        if let own = later.first(where: { failureEvidence($0) == event.payload }) {
            return (own.payload, true)
        }
        guard let result = later.first(where: { candidate in
                  candidate.type == TaskEventTypes.Tool.result.rawValue
                      || (candidate.type == TaskEventTypes.Tool.resultFailed.rawValue
                          && failureEvidence(candidate) == nil)
              }) else {
            return nil
        }
        return (result.payload, result.type == TaskEventTypes.Tool.resultFailed.rawValue)
    }

    /// The `tool.use` payload a failed result names: the recorder stores the
    /// call's own evidence on a failure (`ToolResultFailurePayload`). Nil for
    /// anything else, or a failure recorded without it.
    private static func failureEvidence(_ event: TaskEvent) -> String? {
        guard event.type == TaskEventTypes.Tool.resultFailed.rawValue,
              let data = event.payload.data(using: .utf8) else {
            return nil
        }
        return (try? JSONDecoder().decode(ToolResultFailurePayload.self, from: data))?.toolUseEvidence
    }

    enum Action: Equatable, Sendable {
        case push
        case pullRequest(verb: String)
        case issue(verb: String)
        case release
        case api(method: String)
        /// Any other command that is not known local work, as it was run.
        case command(String)
    }

    /// The command text of a shell tool call, or nil for any other tool. File
    /// tools are excluded on purpose: a document that mentions `gh pr create`
    /// did not open a pull request.
    nonisolated static func shellCommandText(fromToolUsePayload payload: String) -> String? {
        let prefix = "Using tool: "
        guard payload.hasPrefix(prefix) else { return nil }
        let rest = payload.dropFirst(prefix.count)
        let name = rest.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces)
        let lowered = name.lowercased()
        let summary = rest.dropFirst(name.count).drop { $0 == ":" || $0 == " " }
        // The browser MCP tool is recorded as the `astra-browser` command it
        // ran, the same words the approval gate judges.
        if AgentRuntimePolicyGuard.isBrowserBridgeTool(name) {
            return summary.hasPrefix(BrowserBridgeMCPProjection.toolCommand + " ") ? String(summary) : nil
        }
        guard ProviderToolSemantics.isShellTool(name)
                || ["command", "terminal", "exec"].contains(where: lowered.contains) else {
            return nil
        }
        return summary.isEmpty ? nil : String(summary)
    }

    /// What a call that ran this command did outside the machine, for its
    /// record: nothing when the command is known local work
    /// (`LocalShellCommands`), the same reading Ask asks by, so Auto records
    /// exactly what Ask would have asked about. A call that is one recognised
    /// `git push` or `gh` write gets that action's title; any other is
    /// recorded as the command it ran, never as what it may have done.
    nonisolated static func recordedAction(in command: String) -> Action? {
        let text = ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !LocalShellCommands.isLocal(text) else { return nil }
        // One command whose own status is the call's: no separator, and not
        // sent to the background.
        if let commands = LocalShellCommands.simpleCommands(text), commands.count == 1, !text.hasSuffix("&"),
           let action = recognisedAction(commands[0]) {
            return action
        }
        return .command(text)
    }

    nonisolated private static func recognisedAction(_ words: [String]) -> Action? {
        guard let program = words.first else { return nil }
        let args = Array(words.dropFirst())
        switch program {
        case "git":
            let operands = operands(args, optionsWithValues: ["-C", "--git-dir", "--work-tree", "--namespace"])
            // A dry run, alone or in a short-option cluster (`-vn`), pushes
            // nothing, so it is not titled as a push.
            let dryRun = args.contains("--dry-run")
                || args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n") }
            guard operands.first == "push", !dryRun else { return nil }
            return .push
        case "gh":
            // Help and a dry run create nothing, so they are not titled as
            // the action.
            guard !args.contains(where: { ["--help", "-h", "--dry-run"].contains($0) }) else { return nil }
            let operands = operands(args, optionsWithValues: ["-R", "--repo", "--hostname"])
            guard let area = operands.first else { return nil }
            let verb = operands.dropFirst().first ?? ""
            switch area {
            case "pr" where verb == "ready":
                return .pullRequest(verb: args.contains("--undo") ? "draft" : "ready")
            case "pr" where ["create", "merge", "comment", "review", "edit", "close"].contains(verb):
                return .pullRequest(verb: verb)
            case "issue" where ["create", "comment", "edit", "close"].contains(verb):
                return .issue(verb: verb)
            case "release" where verb == "create":
                return .release
            case "api":
                return apiMethod(args).map { .api(method: $0) }
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The write method a `gh api` call uses; nil leaves it a plain command.
    nonisolated private static func apiMethod(_ args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            let method: String?
            if arg == "-X" || arg == "--method" {
                method = args.indices.contains(index + 1) ? args[index + 1] : nil
            } else if arg.hasPrefix("--method=") {
                method = String(arg.dropFirst("--method=".count))
            } else if arg.hasPrefix("-X"), arg.count > 2 {
                method = String(arg.dropFirst(2))
            } else {
                method = nil
            }
            if let method { return ["POST", "PATCH", "PUT", "DELETE"].contains(method.uppercased()) ? method.uppercased() : nil }
        }
        // Fields or a body without a method send a POST.
        let bodyFlags = ["-f", "-F", "--field", "--raw-field", "--input"]
        return args.contains { arg in bodyFlags.contains { arg == $0 || arg.hasPrefix($0) && $0.count == 2 || arg.hasPrefix($0 + "=") } }
            ? "POST" : nil
    }

    nonisolated private static func operands(_ args: [String], optionsWithValues: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if optionsWithValues.contains(arg) {
                index += 2
                continue
            }
            if !arg.hasPrefix("-") { result.append(arg) }
            index += 1
        }
        return result
    }

    /// The command a tool-use summary carries. Providers report a shell call
    /// either as the command itself or as a JSON object with a `command` (or
    /// `cmd`) field, and the recorded summary can be cut off mid-string.
    nonisolated static func commandText(fromSummary summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return trimmed }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "cmd"] {
                if let value = object[key] as? String { return value }
                if let parts = object[key] as? [String] { return parts.joined(separator: " ") }
            }
            return trimmed
        }
        // Truncated JSON: read the command string up to where it stops.
        guard let range = trimmed.range(of: #""(?:command|cmd)"\s*:\s*""#, options: .regularExpression) else {
            return trimmed
        }
        var value = ""
        var escaped = false
        for character in trimmed[range.upperBound...] {
            if escaped {
                value.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                value.append(character)
            }
        }
        return value
    }

    nonisolated static func title(for action: Action, url: String?) -> String {
        let number = url.flatMap(numberedItem)
        switch action {
        case .push:
            return "Pushed commits"
        case .pullRequest(let verb):
            let noun = number.map { "pull request #\($0)" } ?? "a pull request"
            switch verb {
            case "create": return "Opened \(noun)"
            case "merge": return "Merged \(noun)"
            case "comment": return "Commented on \(noun)"
            case "review": return "Reviewed \(noun)"
            case "edit": return "Edited \(noun)"
            case "close": return "Closed \(noun)"
            case "draft": return "Converted \(noun) to draft"
            default: return "Marked \(noun) ready for review"
            }
        case .issue(let verb):
            let noun = number.map { "issue #\($0)" } ?? "an issue"
            switch verb {
            case "create": return "Opened \(noun)"
            case "comment": return "Commented on \(noun)"
            case "edit": return "Edited \(noun)"
            default: return "Closed \(noun)"
            }
        case .release:
            return "Created a release"
        case .api(let method):
            return "Sent a GitHub API \(method) request"
        case .command(let text):
            return "Ran " + commandNames(text)
        }
    }

    /// The programs a command ran outside the local list, by name and
    /// subcommand only (`curl`, `gh gist create`): its arguments can carry a
    /// token, a header or a body, and the title is kept and shown.
    nonisolated static func commandNames(_ text: String) -> String {
        let outside = LocalShellCommands.commandsOutsideTheList(text) ?? []
        var names: [String] = []
        for words in outside {
            let program = words.drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil }
            guard let first = program.first else { continue }
            let programName = (first as NSString).lastPathComponent
            // `gh` names an area and a verb; other programs one subcommand.
            let subcommands = program.dropFirst().prefix(programName == "gh" ? 2 : 1)
                .prefix { $0.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil }
            let name = ([programName] + subcommands).joined(separator: " ")
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return "a command" }
        let shown = names.prefix(3).map { "`\($0)`" }.joined(separator: ", ")
        return names.count > 3 ? shown + " and \(names.count - 3) more" : shown
    }

    nonisolated private static func numberedItem(in url: String) -> String? {
        guard let match = url.range(of: #"/(?:pull|issues)/[0-9]+"#, options: .regularExpression) else { return nil }
        return url[match].split(separator: "/").last.map(String.init)
    }

    /// Where the action landed. `gh` talks to GitHub — or to the GitHub
    /// Enterprise host its `--hostname` or `--repo HOST/OWNER/REPO` names —
    /// but `git push` goes to whatever remote it names, so a push without a
    /// GitHub link reads its destination from Git's own `To <remote>` line, and
    /// says only "Git remote" when that is missing rather than guess GitHub.
    nonisolated static func destination(
        for action: Action,
        url: String?,
        result: String,
        enterprise: (host: String, repository: String?)? = nil
    ) -> String {
        if case .command(let text) = action {
            // The host the command names, or the program it ran.
            let words = LocalShellCommands.simpleCommands(text) ?? []
            return words.joined().lazy.compactMap { URLComponents(string: $0)?.host }.first
                ?? words.first?.first.map { ($0 as NSString).lastPathComponent }
                ?? "Command"
        }
        if let enterprise, action != .push {
            let repository = url.flatMap { URLComponents(string: $0)?.path }
                .map { $0.split(separator: "/").prefix(2).joined(separator: "/") }
                .flatMap { $0.contains("/") ? $0 : nil }
                ?? enterprise.repository
            return repository.map { "\(enterprise.host)/\($0)" } ?? enterprise.host
        }
        if let repository = url.flatMap(ExternalActionRecordProjection.repository(fromGitHubURL:)) {
            return repository
        }
        guard action == .push else { return "GitHub" }
        return pushRemote(in: result) ?? "Git remote"
    }

    /// The GitHub Enterprise host a `gh` command names, with the repository
    /// when `--repo HOST/OWNER/REPO` gives one; nil for github.com.
    nonisolated static func enterpriseGitHub(in command: String) -> (host: String, repository: String?)? {
        let text = ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))
        for tokens in LocalShellCommands.simpleCommands(text) ?? [] {
            func value(after names: Set<String>) -> String? {
                for (index, token) in tokens.enumerated() {
                    if names.contains(token), tokens.indices.contains(index + 1) { return tokens[index + 1] }
                    for name in names where token.hasPrefix(name + "=") { return String(token.dropFirst(name.count + 1)) }
                }
                return nil
            }
            let repoParts = value(after: ["-R", "--repo"])?.split(separator: "/").map(String.init) ?? []
            let host = value(after: ["--hostname"]) ?? (repoParts.count == 3 ? repoParts[0] : nil)
            guard let host, host.lowercased() != "github.com" else { continue }
            return (host, repoParts.count >= 2 ? repoParts.suffix(2).joined(separator: "/") : nil)
        }
        return nil
    }

    /// `owner/repo` when the first `To <remote>` line `git push` prints is a
    /// github.com remote, in any of its spellings; nil otherwise.
    nonisolated static func pushGitHubRepository(in result: String) -> String? {
        guard let match = result.range(of: #"(?m)^To\s+(\S+)"#, options: .regularExpression) else { return nil }
        var remote = String(result[match].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if remote.lowercased().hasSuffix(".git") { remote.removeLast(4) }
        let host: String
        let path: String
        if let components = URLComponents(string: remote), let parsedHost = components.host, components.scheme != nil {
            (host, path) = (parsedHost, components.path)
        } else if let colon = remote.firstIndex(of: ":") {
            host = remote[..<colon].split(separator: "@").last.map(String.init) ?? ""
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        let parts = path.split(separator: "/").map(String.init)
        guard host.lowercased() == "github.com", parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    /// `owner/repo` for GitHub, otherwise `host/path`, read from the first
    /// `To <remote>` line `git push` prints.
    nonisolated static func pushRemote(in result: String) -> String? {
        guard let match = result.range(of: #"(?m)^To\s+(\S+)"#, options: .regularExpression) else { return nil }
        var remote = String(result[match].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if remote.lowercased().hasSuffix(".git") { remote.removeLast(4) }
        let hostAndPath: (host: String, path: String)
        if let components = URLComponents(string: remote), let host = components.host, components.scheme != nil {
            hostAndPath = (host, components.path)
        } else if let colon = remote.firstIndex(of: ":") {
            // scp-like `git@host:owner/repo`.
            let host = remote[..<colon].split(separator: "@").last.map(String.init) ?? ""
            hostAndPath = (host, String(remote[remote.index(after: colon)...]))
        } else {
            return nil
        }
        let path = hostAndPath.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !hostAndPath.host.isEmpty else { return nil }
        if hostAndPath.host.lowercased() == "github.com", !path.isEmpty { return path }
        return path.isEmpty ? hostAndPath.host : "\(hostAndPath.host)/\(path)"
    }

    /// The first http(s) address in `text`, reduced to scheme and host: a
    /// user, password, path or query string can carry a secret (a webhook
    /// token is often the path) the record must not show.
    nonisolated static func firstWebURL(in text: String) -> String? {
        guard let match = text.range(of: #"https?://[^\s"'\)<>\]\\,]+"#, options: .regularExpression),
              var components = URLComponents(string: String(text[match])),
              components.host?.isEmpty == false else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        var url = components.string ?? ""
        while let last = url.last, ".;:".contains(last) { url.removeLast() }
        return url.isEmpty ? nil : url
    }

    nonisolated static func firstGitHubURL(in text: String, host: String? = nil) -> String? {
        let escapedHost = NSRegularExpression.escapedPattern(for: host ?? "github.com")
        guard let match = text.range(of: #"https://"# + escapedHost + #"/[^\s"'\)<>\]\\,]+"#, options: .regularExpression) else {
            return nil
        }
        var url = String(text[match])
        while let last = url.last, ".;:".contains(last) { url.removeLast() }
        return canonicalGitHubURL(url)
    }

    /// A GitHub link reduced to the resource it names — the repository, a
    /// pull request or issue by number, or a release tag — without a user,
    /// query or fragment, which can carry a token the record must not keep.
    nonisolated static func canonicalGitHubURL(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme,
              let host = components.host, !host.isEmpty else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var kept = Array(parts.prefix(2))
        if parts.count >= 4, ["pull", "issues"].contains(parts[2]), Int(parts[3]) != nil {
            kept = Array(parts.prefix(4))
        } else if parts.count >= 5, parts[2] == "releases", parts[3] == "tag" {
            kept = Array(parts.prefix(5))
        }
        // An HTTPS remote (`To https://github.com/o/r.git`) names the repository.
        if kept.count == 2, kept[1].lowercased().hasSuffix(".git") { kept[1].removeLast(4) }
        return "\(scheme)://\(host)" + (kept.isEmpty ? "" : "/" + kept.joined(separator: "/"))
    }
}

/// The record row for an action the agent took with its own tools.
enum ObservedExternalActionRecordSource: ExternalActionRecordSource {
    /// An Auto run's result markers carry the verdict and are the record
    /// themselves, so a run interrupted before its boundary keeps it; older
    /// runs were recorded at the boundary as observations.
    static let eventTypes: Set<String> = [AgentExternalActionObserver.eventType, AgentExternalActionObserver.resultEventType]

    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        let decoder = TaskEventPayloadCodec.makeDecoder()
        let observation: AgentExternalActionObserver.Observation
        if let marker = try? decoder.decode(AgentExternalActionObserver.ResultMarker.self, from: payload) {
            guard let verdict = marker.verdict,
                  let derived = AgentExternalActionObserver.observation(
                      of: verdict, sourceEventID: eventID, output: marker.output, failed: marker.failed == true
                  ) else { return nil }
            observation = derived
        } else if let stored = try? decoder.decode(AgentExternalActionObserver.Observation.self, from: payload) {
            observation = stored
        } else {
            return nil
        }
        return ExternalActionRecord(
            id: eventID,
            kind: .agentCommand,
            title: observation.title,
            destination: observation.destination,
            url: observation.url.flatMap(URL.init(string:)),
            authorization: .agentObserved,
            timestamp: timestamp,
            legacyNotices: []
        )
    }
}
