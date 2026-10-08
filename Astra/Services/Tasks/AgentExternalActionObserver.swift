import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// What an Auto run's agent did outside the machine with its own tools.
///
/// In Auto the agent holds native Git and GitHub credentials and can push,
/// open a pull request, or comment with `gh` itself; ASTRA never sees those as
/// typed actions with receipts. This reads the run's own tool calls at the run
/// boundary and records the recognisable ones so the chat can say what was done
/// on the user's behalf, with the link the command printed.
///
/// A record, never a gate, and best effort by construction: it recognises a
/// fixed set of `git` and `gh` commands, records only calls whose result came
/// back successful, and claims nothing it did not see. Nothing about whether
/// the command was allowed depends on it.
@MainActor
enum AgentExternalActionObserver {
    static let eventType = "external.action.observed"
    /// The successful result of a call that ran a recognised external action,
    /// named by that call's evidence (the `tool.use` payload). Not shown in
    /// the thread; it is what pairs a result with its own call.
    static let resultEventType = "external.action.result"

    struct ResultMarker: Codable, Equatable, Sendable {
        var version = 1
        let toolUseEvidence: String
        let output: String
    }

    nonisolated static func resultMarker(evidence: String, output: String) -> ResultMarker? {
        guard let command = shellCommandText(fromToolUsePayload: evidence),
              !recordableActions(in: command).isEmpty else { return nil }
        return ResultMarker(toolUseEvidence: evidence, output: String(output.prefix(4_000)))
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
            guard let command = shellCommandText(fromToolUsePayload: event.payload) else { continue }
            let actions = recordableActions(in: command)
            guard !actions.isEmpty else { continue }
            let output: String
            if pairsByMarker {
                guard let position = markers.firstIndex(where: { $0.toolUseEvidence == event.payload }) else { continue }
                output = markers.remove(at: position).output
            } else {
                guard let fallback = fallbackResult(after: index, call: event, in: runEvents) else { continue }
                output = fallback
            }
            let enterprise = enterpriseGitHub(in: command)
            let urls = actionURLs(for: actions, output: output, command: command, host: enterprise?.host)
            for (action, url) in zip(actions, urls) {
                let observation = Observation(
                    sourceEventID: event.id,
                    title: title(for: action, url: url),
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

    /// One link per action. A single action takes the first link printed; in
    /// a compound call each takes the first unused link of its own kind (a
    /// pull request's `/pull/`, an issue's `/issues/`), and an action with
    /// none gets no link rather than another action's.
    static func actionURLs(for actions: [Action], output: String, command: String, host: String?) -> [String?] {
        guard actions.count > 1 else {
            return [firstGitHubURL(in: output, host: host) ?? firstGitHubURL(in: command, host: host)]
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
    /// call that is not known to be another call's.
    private static func fallbackResult(after index: Int, call event: TaskEvent, in runEvents: [TaskEvent]) -> String? {
        // A failed result names the call it belongs to (a batch can answer
        // another call first); a successful one does not, so the first result
        // not known to be someone else's decides, and a missing result is not
        // evidence of an action.
        let later = runEvents[(index + 1)...]
        guard !later.contains(where: { failureEvidence($0) == event.payload }),
              let result = later.first(where: { candidate in
                  candidate.type == TaskEventTypes.Tool.result.rawValue
                      || (candidate.type == TaskEventTypes.Tool.resultFailed.rawValue
                          && failureEvidence(candidate) == nil)
              }),
              result.type == TaskEventTypes.Tool.result.rawValue else {
            return nil
        }
        return result.payload
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
        /// A write outside the machine by any other command, with the host it
        /// went to when the command named one.
        case externalWrite(executable: String, destination: String)

        var isExternalWrite: Bool {
            if case .externalWrite = self { return true }
            return false
        }
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
        guard ProviderToolSemantics.isShellTool(name)
                || ["command", "terminal", "exec"].contains(where: lowered.contains) else {
            return nil
        }
        let summary = rest.dropFirst(name.count).drop { $0 == ":" || $0 == " " }
        return summary.isEmpty ? nil : String(summary)
    }

    /// The first recognised external action the command runs.
    ///
    /// Only an executable position counts. The command is split into segments
    /// on the separators a shell honours outside quotes, and each segment's
    /// executable is read after assignments and prefixes such as `env`: a
    /// quoted operand like `rg 'git push' .` or `echo 'gh pr create'` names a
    /// command without running it. `unwrapping: false` reads each segment as
    /// written, for a caller that unwraps runners and `sh -c` itself.
    nonisolated static func classify(_ command: String, unwrapping: Bool = true) -> Action? {
        actions(in: command, depth: unwrapping ? 0 : maximumUnwrapDepth).first
    }

    /// Every recognised external action the command runs, in order —
    /// `git push && gh pr create` did two things — including what a runner
    /// (`env -u CI`, `timeout 30`, `xargs`) or `sh -c` runs.
    nonisolated static func actions(in command: String, depth: Int = 0) -> [Action] {
        let text = ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))
        return shellSegments(text).flatMap { actions(forSegment: $0, depth: depth) }
    }

    /// The actions whose own failure would fail the call, so a successful
    /// result proves they happened: none masked by `|| true`, a pipe, a later
    /// `;`, a background `&`, or a substitution — only `&&` may follow them.
    /// What the record claims; `actions(in:)` is what the guard asks about.
    nonisolated static func recordableActions(in command: String, depth: Int = 0) -> [Action] {
        let text = ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))
        let segments = shellSegmentsWithSeparators(text)
        return segments.indices.flatMap { index -> [Action] in
            let decisive = (index..<segments.count).allSatisfy { later in
                let separator = segments[later].trailing.trimmingCharacters(in: .whitespacesAndNewlines)
                return later == segments.count - 1 ? ["", ";", "&&"].contains(separator) : separator == "&&"
            }
            guard decisive else { return [] }
            return actions(forSegment: segments[index].tokens, depth: depth, recordable: true)
        }
    }

    nonisolated private static let maximumUnwrapDepth = 4

    nonisolated private static func actions(forSegment rawTokens: [String], depth: Int, recordable: Bool = false) -> [Action] {
        var tokens = rawTokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "(){}")) }.filter { !$0.isEmpty }
        while let first = tokens.first,
              (first.contains("=") && !first.hasPrefix("-")) || commandPrefixes.contains(first.lowercased()) {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return [] }
        if depth < maximumUnwrapDepth {
            if let inner = ShellCommandRunners.wrappedCommand(tokens.joined(separator: " ")) {
                return recordable ? recordableActions(in: inner, depth: depth + 1) : actions(in: inner, depth: depth + 1)
            }
            if let payload = shellPayload(tokens) {
                return recordable ? recordableActions(in: payload, depth: depth + 1) : actions(in: payload, depth: depth + 1)
            }
        }
        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        let args = Array(tokens.dropFirst()).map { $0.lowercased() }
        switch executable {
        case "git":
            guard ["push", "send-pack"].contains(
                      firstOperand(args, optionsWithValues: ["-c", "-C", "--git-dir", "--work-tree", "--namespace"])
                  ),
                  !args.contains("--dry-run"), !args.contains("-n") else {
                return []
            }
            return [.push]
        case "gh":
            let operands = operands(args, optionsWithValues: ["-r", "--repo", "--hostname"])
            guard let area = operands.first else { return [] }
            let verb = operands.dropFirst().first ?? ""
            switch area {
            case "pr" where verb == "ready":
                return [.pullRequest(verb: args.contains("--undo") ? "draft" : "ready")]
            case "pr" where ["create", "merge", "comment", "review", "edit", "close"].contains(verb):
                return [.pullRequest(verb: verb)]
            case "issue" where ["create", "comment", "edit", "close"].contains(verb):
                return [.issue(verb: verb)]
            case "release" where verb == "create":
                return [.release]
            case "api":
                return apiAction(args).map { [$0] } ?? []
            default:
                // Any other gh write the classifier knows (`gist create`,
                // `workflow run`), by its area and verb.
                guard ShellCommandRiskClassifier.actsOutsideMachine(forShellSegment: tokens.joined(separator: " ")) else {
                    return []
                }
                return [.externalWrite(executable: "gh \(area) \(verb)", destination: "GitHub")]
            }
        default:
            // Any other command the shared risk classifier calls a write
            // outside this machine: a curl that sends data, a cloud deploy, a
            // package publish. Its own tokens, so case still reads (`-X`).
            guard ShellCommandRiskClassifier.actsOutsideMachine(forShellSegment: tokens.joined(separator: " ")) else {
                return []
            }
            let host = tokens.lazy.compactMap { URLComponents(string: $0)?.host }.first
            return [.externalWrite(executable: executable, destination: host ?? executable)]
        }
    }

    /// The command string of `sh|bash|zsh|dash|ksh -c <payload>`.
    nonisolated private static func shellPayload(_ tokens: [String]) -> String? {
        guard let first = tokens.first,
              ["sh", "bash", "zsh", "dash", "ksh"].contains(URL(fileURLWithPath: first).lastPathComponent.lowercased()) else {
            return nil
        }
        var index = 1
        while index < tokens.count, tokens[index].hasPrefix("-") {
            let option = tokens[index]
            if !option.hasPrefix("--"), option.contains("c") {
                return tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
            }
            index += option == "-o" ? 2 : 1
        }
        return nil
    }

    /// `gh api` writes when given a write method, or — on its own — when given
    /// fields or a body.
    nonisolated private static func apiAction(_ args: [String]) -> Action? {
        for (index, arg) in args.enumerated() {
            let method: String?
            if arg == "-x" || arg == "--method" {
                method = args.indices.contains(index + 1) ? args[index + 1] : nil
            } else if arg.hasPrefix("--method=") {
                method = String(arg.dropFirst("--method=".count))
            } else if arg.hasPrefix("-x"), arg.count > 2 {
                method = String(arg.dropFirst(2))
            } else {
                method = nil
            }
            if let method, ["post", "patch", "put", "delete"].contains(method) {
                return .api(method: method.uppercased())
            }
            // `--method GET` sends fields as a query string: a read.
            if let method, ["get", "head"].contains(method) {
                return nil
            }
        }
        let bodyFlags: Set<String> = ["-f", "--field", "--raw-field", "--input"]
        // `-fkey=value` (and `-Fkey=value`, lowercased here) attaches the field.
        let attachedField: (String) -> Bool = { $0.hasPrefix("-f") && !$0.hasPrefix("--") && $0.count > 2 }
        if args.contains(where: { arg in
            bodyFlags.contains(arg) || bodyFlags.contains { arg.hasPrefix($0 + "=") } || attachedField(arg)
        }) {
            return .api(method: "POST")
        }
        return nil
    }

    nonisolated private static let commandPrefixes: Set<String> = [
        "env", "command", "builtin", "exec", "time", "nohup", "sudo", "then", "do", "else", "if", "elif", "while", "until", "!"
    ]

    nonisolated private static func operands(_ args: [String], optionsWithValues: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if optionsWithValues.contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                index += 1
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    nonisolated private static func firstOperand(_ args: [String], optionsWithValues: Set<String>) -> String? {
        operands(args, optionsWithValues: optionsWithValues).first
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

    /// Splits a command into the token lists of the commands it runs. Quotes
    /// group text and are dropped; `;`, `&&`, `||`, `|`, `&`, newlines, and
    /// subshell parentheses separate commands outside quotes, and command
    /// substitution (`$(` or a backtick) starts one anywhere but inside single
    /// quotes.
    nonisolated static func shellSegments(_ command: String) -> [[String]] {
        shellSegmentsWithSeparators(command).map(\.tokens)
    }

    /// `shellSegments`, with the operator that ended each segment (`&&`,
    /// `||`, `|`, `;`, `$(`, `)`), which decides whether the segment's own
    /// status is the call's.
    nonisolated static func shellSegmentsWithSeparators(_ command: String) -> [(tokens: [String], trailing: String)] {
        var segments: [(tokens: [String], trailing: String)] = []
        var tokens: [String] = []
        var token = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        // A `$(` opened inside double quotes runs unquoted until its `)`; the
        // quote state to return to is kept per nesting level.
        var substitutions: [Bool] = []
        func endToken() {
            if !token.isEmpty { tokens.append(token) }
            token = ""
        }
        func endSegment(_ separator: String) {
            endToken()
            if !tokens.isEmpty {
                segments.append((tokens, separator))
            } else if !segments.isEmpty {
                segments[segments.count - 1].trailing += separator
            }
            tokens = []
        }
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\", !inSingle {
                escaped = true
                continue
            }
            if inSingle {
                if character == "'" { inSingle = false } else { token.append(character) }
                continue
            }
            if character == "$", next == "(" {
                endSegment("$(")
                substitutions.append(inDouble)
                inDouble = false
                index += 1
                continue
            }
            if character == "`" {
                endSegment("`")
                continue
            }
            if inDouble {
                if character == "\"" { inDouble = false } else { token.append(character) }
                continue
            }
            switch character {
            case "'":
                inSingle = true
            case "\"":
                inDouble = true
            case ")" where !substitutions.isEmpty:
                endSegment(")")
                inDouble = substitutions.removeLast()
            case ";", "|", "&", "\n", "(", ")":
                endSegment(String(character))
            case _ where character.isWhitespace:
                endToken()
            default:
                token.append(character)
            }
        }
        endSegment("")
        return segments
    }

    static func title(for action: Action, url: String?) -> String {
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
        case .externalWrite(let executable, _):
            return "Ran \(executable), which changed something outside ASTRA"
        }
    }

    private static func numberedItem(in url: String) -> String? {
        guard let match = url.range(of: #"/(?:pull|issues)/[0-9]+"#, options: .regularExpression) else { return nil }
        return url[match].split(separator: "/").last.map(String.init)
    }

    /// Where the action landed. `gh` talks to GitHub — or to the GitHub
    /// Enterprise host its `--hostname` or `--repo HOST/OWNER/REPO` names —
    /// but `git push` goes to whatever remote it names, so a push without a
    /// GitHub link reads its destination from Git's own `To <remote>` line, and
    /// says only "Git remote" when that is missing rather than guess GitHub.
    static func destination(
        for action: Action,
        url: String?,
        result: String,
        enterprise: (host: String, repository: String?)? = nil
    ) -> String {
        if case .externalWrite(_, let destination) = action { return destination }
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
        for tokens in shellSegments(ProviderToolSemantics.semanticShellCommand(commandText(fromSummary: command))) {
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

    /// `owner/repo` for GitHub, otherwise `host/path`, read from the first
    /// `To <remote>` line `git push` prints.
    static func pushRemote(in result: String) -> String? {
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

    static func firstGitHubURL(in text: String, host: String? = nil) -> String? {
        let escapedHost = NSRegularExpression.escapedPattern(for: host ?? "github.com")
        guard let match = text.range(of: #"https://"# + escapedHost + #"/[^\s"'\)<>\]\\,]+"#, options: .regularExpression) else {
            return nil
        }
        var url = String(text[match])
        while let last = url.last, ".;:".contains(last) { url.removeLast() }
        return url
    }
}

/// The record row for an action the agent took with its own tools.
enum ObservedExternalActionRecordSource: ExternalActionRecordSource {
    static let eventTypes: Set<String> = [AgentExternalActionObserver.eventType]

    static func record(payload: Data, eventID: UUID, timestamp: Date) -> ExternalActionRecord? {
        guard let observation = try? TaskEventPayloadCodec.makeDecoder()
            .decode(AgentExternalActionObserver.Observation.self, from: payload) else {
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
