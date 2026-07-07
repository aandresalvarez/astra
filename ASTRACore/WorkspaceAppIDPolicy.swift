import Foundation

public enum WorkspaceAppIDPolicy {
    public static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    public static func isPortableIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && !trimmed.isEmpty
            && trimmed.rangeOfCharacter(from: allowedCharacters.inverted) == nil
            && !isReservedPathComponent(trimmed)
    }

    public static func isReservedPathComponent(_ value: String) -> Bool {
        value == "."
            || value == ".."
            || value.caseInsensitiveCompare("exports") == .orderedSame
    }
}
