import Foundation

enum PermissionPolicy: String, Codable, CaseIterable {
    case autonomous
    case restricted
    case interactive

    var cliArguments: [String] {
        switch self {
        case .autonomous:
            return ["--dangerously-skip-permissions"]
        case .restricted, .interactive:
            return []
        }
    }

    func subAgentPermissions(allowedTools: [String]) -> [[String: Any]] {
        switch self {
        case .autonomous:
            return [
                ["allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Grep(*)", "Glob(*)"],
                 "deny": [] as [String]]
            ]
        case .restricted:
            let allow = allowedTools.isEmpty
                ? ["Read(*)", "Glob(*)", "Grep(*)"]
                : allowedTools.map { "\($0)(*)" }
            return [
                ["allow": allow, "deny": [] as [String]]
            ]
        case .interactive:
            return []
        }
    }
}
