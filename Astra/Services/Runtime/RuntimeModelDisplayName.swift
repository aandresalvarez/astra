import Foundation

enum RuntimeModelDisplayName {
    static func displayName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("gpt-") else {
            return trimmed
        }

        return trimmed
            .split(separator: "-")
            .map(displayComponent)
            .joined(separator: "-")
    }

    private static func displayComponent(_ component: Substring) -> String {
        let lower = component.lowercased()
        switch lower {
        case "gpt":
            return "GPT"
        case "mini":
            return "Mini"
        case "codex":
            return "Codex"
        case "spark":
            return "Spark"
        default:
            return String(component)
        }
    }
}
