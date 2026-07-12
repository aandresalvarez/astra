import Foundation

/// Applies fork-local file mappings only at complete path-token boundaries.
public enum TaskForkPathRewriter {
    public static func rewrite(_ text: String, using mapping: [String: String]) -> String {
        mapping.keys.sorted { $0.count > $1.count }.reduce(text) { value, sourcePath in
            guard let replacement = mapping[sourcePath], !sourcePath.isEmpty else { return value }
            var result = value
            var searchStart = result.startIndex
            while let range = result.range(of: sourcePath, range: searchStart..<result.endIndex) {
                let beforeIsBoundary = range.lowerBound == result.startIndex
                    || !isPathTokenCharacter(result[result.index(before: range.lowerBound)])
                let afterIsBoundary = range.upperBound == result.endIndex
                    || !isPathTokenCharacter(result[range.upperBound])
                if beforeIsBoundary && afterIsBoundary {
                    let lowerOffset = result.distance(from: result.startIndex, to: range.lowerBound)
                    result.replaceSubrange(range, with: replacement)
                    searchStart = result.index(result.startIndex, offsetBy: lowerOffset + replacement.count)
                } else {
                    searchStart = range.upperBound
                }
            }
            return result
        }
    }

    private static func isPathTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "._-/~".contains(character)
    }
}
