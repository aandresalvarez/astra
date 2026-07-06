import Foundation
import ASTRAModels

struct AstraExternalRoute: Equatable, Identifiable, Sendable {
    enum Destination: Equatable, Sendable {
        case workspace(UUID)
        case task(UUID)
        case createTask(workspaceID: UUID, goal: String, shouldRun: Bool)
        case continueLatestUnfinishedTask(workspaceID: UUID)
    }

    let id: UUID
    let destination: Destination

    init(id: UUID = UUID(), destination: Destination) {
        self.id = id
        self.destination = destination
    }
}

enum AstraExternalRouteCodec {
    static func url(for route: AstraExternalRoute, channel: AppChannel = .current) -> URL? {
        var components = URLComponents()
        components.scheme = scheme(for: channel)

        switch route.destination {
        case .workspace(let workspaceID):
            components.host = "workspace"
            components.path = "/\(workspaceID.uuidString)"

        case .task(let taskID):
            components.host = "task"
            components.path = "/\(taskID.uuidString)"

        case .createTask(let workspaceID, let goal, let shouldRun):
            components.host = "create-task"
            components.queryItems = [
                URLQueryItem(name: "workspace", value: workspaceID.uuidString),
                URLQueryItem(name: "goal", value: goal),
                URLQueryItem(
                    name: "run",
                    value: AstraExternalRouteRunAuthorization.urlQueryValue(forRequestedRun: shouldRun)
                )
            ]

        case .continueLatestUnfinishedTask(let workspaceID):
            components.host = "continue"
            components.queryItems = [
                URLQueryItem(name: "workspace", value: workspaceID.uuidString)
            ]
        }

        return components.url
    }

    static func route(from url: URL, channel: AppChannel = .current) -> AstraExternalRoute? {
        guard url.scheme == scheme(for: channel),
              let host = url.host else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = queryValues(from: components?.queryItems ?? [])

        switch host {
        case "workspace":
            guard let workspaceID = uuidPathComponent(from: url) else { return nil }
            return AstraExternalRoute(destination: .workspace(workspaceID))

        case "task":
            guard let taskID = uuidPathComponent(from: url) else { return nil }
            return AstraExternalRoute(destination: .task(taskID))

        case "create-task":
            guard let workspaceValue = query["workspace"],
                  let workspaceID = UUID(uuidString: workspaceValue),
                  let goal = query["goal"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !goal.isEmpty else {
                return nil
            }
            let requestedRun = query["run"] == "1" || query["run"]?.lowercased() == "true"
            let shouldRun = AstraExternalRouteRunAuthorization.allowsImmediateRunFromExternalURL(
                requestedRun: requestedRun
            )
            return AstraExternalRoute(
                destination: .createTask(workspaceID: workspaceID, goal: goal, shouldRun: shouldRun)
            )

        case "continue":
            guard let workspaceValue = query["workspace"],
                  let workspaceID = UUID(uuidString: workspaceValue) else {
                return nil
            }
            return AstraExternalRoute(destination: .continueLatestUnfinishedTask(workspaceID: workspaceID))

        default:
            return nil
        }
    }

    static func scheme(for channel: AppChannel) -> String {
        switch channel {
        case .production: "astra"
        case .development: "astra-dev"
        case .beta: "astra-beta"
        }
    }

    private static func uuidPathComponent(from url: URL) -> UUID? {
        let value = url.pathComponents.dropFirst().first
        return value.flatMap(UUID.init(uuidString:))
    }

    private static func queryValues(from items: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, values[item.name] == nil else { continue }
            values[item.name] = value
        }
        return values
    }
}

private enum AstraExternalRouteRunAuthorization {
    static func urlQueryValue(forRequestedRun requestedRun: Bool) -> String {
        allowsImmediateRunFromExternalURL(requestedRun: requestedRun) ? "1" : "0"
    }

    static func allowsImmediateRunFromExternalURL(requestedRun _: Bool) -> Bool {
        false
    }
}

enum AstraTaskIntentSupport {
    static func title(for goal: String) -> String {
        let firstLine = goal
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "New ASTRA Task" }
        if firstLine.count <= 60 { return firstLine }

        let prefix = String(firstLine.prefix(57))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    static func draftMessagesJSON(for goal: String) -> String {
        struct DraftMessage: Codable {
            let role: String
            let content: String
        }

        let messages = [DraftMessage(role: "user", content: goal)]
        guard let data = try? JSONEncoder().encode(messages),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func latestUnfinishedTask(in workspace: Workspace) -> AgentTask? {
        workspace.tasks
            .filter { task in
                !task.isDone && !task.isTerminal
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
            .first
    }
}
