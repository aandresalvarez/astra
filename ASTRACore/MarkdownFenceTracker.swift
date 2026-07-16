import Foundation

/// Tracks CommonMark fenced-code boundaries so every text-normalization pass
/// agrees about which lines are protected content.
struct MarkdownFenceTracker {
    private var openFence: (character: Character, length: Int)?

    mutating func protects(_ line: String) -> Bool {
        guard let descriptor = Self.fenceDescriptor(for: line) else {
            return openFence != nil
        }

        if let openFence {
            if descriptor.character == openFence.character,
               descriptor.length >= openFence.length,
               descriptor.hasWhitespaceOnlySuffix {
                self.openFence = nil
            }
        } else {
            openFence = (descriptor.character, descriptor.length)
        }
        return true
    }

    private static func fenceDescriptor(
        for line: String
    ) -> (character: Character, length: Int, hasWhitespaceOnlySuffix: Bool)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let candidate = line.dropFirst(leadingSpaces)
        guard let character = candidate.first, character == "`" || character == "~" else {
            return nil
        }
        let length = candidate.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let suffix = candidate.dropFirst(length)
        return (
            character,
            length,
            suffix.allSatisfy { $0 == " " || $0 == "\t" }
        )
    }
}
