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
        var observations: [Observation] = []
        for (index, event) in runEvents.enumerated()
        where event.type == TaskEventTypes.Tool.use.rawValue && !alreadyRecorded.contains(event.id) {
            guard let command = shellCommandText(fromToolUsePayload: event.payload),
                  let action = classify(command) else {
                continue
            }
            // The call's own result decides whether anything happened. A failed
            // or missing result is not evidence of an action.
            guard let result = runEvents[(index + 1)...].first(where: {
                $0.type == TaskEventTypes.Tool.result.rawValue || $0.type == TaskEventTypes.Tool.resultFailed.rawValue
            }), result.type == TaskEventTypes.Tool.result.rawValue else {
                continue
            }
            let url = firstGitHubURL(in: result.payload) ?? firstGitHubURL(in: command)
            let observation = Observation(
                sourceEventID: event.id,
                title: title(for: action, url: url),
                destination: destination(for: action, url: url, result: result.payload),
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
        return observations
    }

    enum Action: Equatable, Sendable {
        case push
        case pullRequest(verb: String)
        case issue(verb: String)
        case release
        case api(method: String)
    }

    /// The command text of a shell tool call, or nil for any other tool. File
    /// tools are excluded on purpose: a document that mentions `gh pr create`
    /// did not open a pull request.
    static func shellCommandText(fromToolUsePayload payload: String) -> String? {
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

    static func classify(_ command: String) -> Action? {
        let text = " " + command.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.range(of: #"[\s;&|(`"']git( -c [^ ]+)* push\b"#, options: .regularExpression) != nil {
            return .push
        }
        let prVerbs = ["create", "merge", "comment", "review", "edit", "close", "ready"]
        if let verb = verb(after: "gh pr", in: text, among: prVerbs) { return .pullRequest(verb: verb) }
        if let verb = verb(after: "gh issue", in: text, among: ["create", "comment", "edit", "close"]) {
            return .issue(verb: verb)
        }
        if text.range(of: #"[\s;&|(`"']gh release create\b"#, options: .regularExpression) != nil { return .release }
        if text.range(of: #"[\s;&|(`"']gh api\b"#, options: .regularExpression) != nil {
            if let match = text.range(of: #"(?:-x|--method)[ =](post|patch|put|delete)\b"#, options: .regularExpression) {
                let method = text[match].split(whereSeparator: { $0 == " " || $0 == "=" }).last.map(String.init) ?? "post"
                return .api(method: method.uppercased())
            }
            // `gh api` sends a POST on its own when it is given fields or a body.
            if text.range(of: #" (?:-f|-F|--field|--raw-field|--input)[ =]"#, options: .regularExpression) != nil {
                return .api(method: "POST")
            }
        }
        return nil
    }

    private static func verb(after command: String, in text: String, among verbs: [String]) -> String? {
        let pattern = #"[\s;&|(`"']"# + NSRegularExpression.escapedPattern(for: command)
            + #" ("# + verbs.joined(separator: "|") + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
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
        }
    }

    private static func numberedItem(in url: String) -> String? {
        guard let match = url.range(of: #"/(?:pull|issues)/[0-9]+"#, options: .regularExpression) else { return nil }
        return url[match].split(separator: "/").last.map(String.init)
    }

    /// Where the action landed. `gh` only talks to GitHub, but `git push` goes
    /// to whatever remote it names, so a push without a GitHub link reads its
    /// destination from Git's own `To <remote>` line, and says only "Git
    /// remote" when that is missing rather than guess GitHub.
    static func destination(for action: Action, url: String?, result: String) -> String {
        if let repository = url.flatMap(ExternalActionRecordProjection.repository(fromGitHubURL:)) {
            return repository
        }
        guard action == .push else { return "GitHub" }
        return pushRemote(in: result) ?? "Git remote"
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

    static func firstGitHubURL(in text: String) -> String? {
        guard let match = text.range(of: #"https://github\.com/[^\s"'\)<>\]\\,]+"#, options: .regularExpression) else {
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
