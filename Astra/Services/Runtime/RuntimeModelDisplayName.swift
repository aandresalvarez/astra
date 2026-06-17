import Foundation

enum RuntimeModelDisplayName {
    static func displayName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let lower = modelID.lowercased()

        if let claudeFamilyVersion = familyVersionLabel(in: modelID), lower.hasPrefix("claude-") {
            return "Claude \(claudeFamilyVersion)"
        }

        guard lower.hasPrefix("gpt-") else {
            return trimmed
        }

        return modelID
            .split(separator: "-")
            .map(displayComponent)
            .joined(separator: "-")
    }

    static func familyVersionLabel(in value: String) -> String? {
        guard let match = familyVersionRegex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.numberOfRanges == 4,
              let familyRange = Range(match.range(at: 1), in: value),
              let majorRange = Range(match.range(at: 2), in: value),
              let minorRange = Range(match.range(at: 3), in: value) else {
            return nil
        }

        let family = displayFamily(String(value[familyRange]))
        return "\(family) \(value[majorRange]).\(value[minorRange])"
    }

    private static let familyVersionRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[^a-z])(opus|sonnet|haiku|fable|mythos)[\s._-]+([0-9]+)[\s._-]+([0-9]+)(?:[^0-9]|$)"#
    )

    private static func displayFamily(_ family: String) -> String {
        let lower = family.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
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
