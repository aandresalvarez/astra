import Foundation

/// Tracks CommonMark fenced-code boundaries so every text-normalization pass
/// agrees about which lines are protected content.
struct MarkdownFenceTracker {
    private var openFence: (character: Character, length: Int)?

    mutating func protects(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let descriptor = Self.fenceDescriptor(for: trimmed) else {
            return openFence != nil
        }

        if let openFence {
            if descriptor.character == openFence.character,
               descriptor.length >= openFence.length {
                self.openFence = nil
            }
        } else {
            openFence = descriptor
        }
        return true
    }

    private static func fenceDescriptor(for line: String) -> (character: Character, length: Int)? {
        guard let character = line.first, character == "`" || character == "~" else {
            return nil
        }
        let length = line.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        return (character, length)
    }
}
