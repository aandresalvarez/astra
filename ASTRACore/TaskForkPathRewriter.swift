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
                    // Indices are invalidated by the mutation; resume from a
                    // character offset computed before it.
                    let resumeOffset = result.distance(from: result.startIndex, to: range.lowerBound)
                        + replacement.count
                    result.replaceSubrange(range, with: replacement)
                    searchStart = result.index(result.startIndex, offsetBy: resumeOffset)
                } else {
                    searchStart = range.upperBound
                }
            }
            return result
        }
    }

    /// The manifest maps source paths as recorded, but conversation text and
    /// generated files can spell the same file as the raw input string, the
    /// tilde-expanded absolute path, or a `~/`-prefixed form. Rewrites must
    /// catch every spelling or they keep pointing at the shared original.
    public static func expandedMapping(
        _ mapping: [String: String],
        originalSpellings: [String] = []
    ) -> [String: String] {
        guard !mapping.isEmpty else { return mapping }
        var expanded = mapping
        for (sourcePath, local) in mapping {
            let absolute = (sourcePath as NSString).expandingTildeInPath
            if expanded[absolute] == nil {
                expanded[absolute] = local
            }
        }
        for raw in originalSpellings {
            let absolute = (raw as NSString).expandingTildeInPath
            if expanded[raw] == nil, let local = expanded[absolute] {
                expanded[raw] = local
            }
        }
        let homePrefix = NSHomeDirectory() + "/"
        for (sourcePath, local) in expanded where sourcePath.hasPrefix(homePrefix) {
            let tildeSpelling = "~/" + sourcePath.dropFirst(homePrefix.count)
            if expanded[tildeSpelling] == nil {
                expanded[tildeSpelling] = local
            }
        }
        return expanded
    }

    private static func isPathTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "._-/~".contains(character)
    }
}
