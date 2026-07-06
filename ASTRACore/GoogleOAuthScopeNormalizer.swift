import Foundation

// Moved here as part of Track A3 (extracting the ASTRAModels SwiftPM
// target) so `Astra/Models/GoogleOAuthAccountProfile.swift` can depend on it
// without pulling in the rest of `Astra/Services/GoogleWorkspace/
// GoogleOAuthTypes.swift` (OAuth token-exchange types with app-side
// dependencies that stay behind). Pure string normalization, no I/O.
public enum GoogleOAuthScopeNormalizer {
    public static func normalized(_ scopes: [String]) -> [String] {
        var seen = Set<String>()
        return scopes
            .flatMap { $0.split(separator: " ").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    public static func missing(required: [String], granted: [String]) -> [String] {
        let grantedSet = Set(normalized(granted))
        return normalized(required).filter { !grantedSet.contains($0) }
    }
}
