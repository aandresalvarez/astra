import Foundation

/// The one rule for a name a workspace file supplies for an account (its row
/// name or a binding's alias): it is shown as a row, carried into connector
/// snapshots and `ASTRA_CONNECTORS`, and compared to disambiguate, so it is a
/// single line of visible text. Format characters (bidirectional controls,
/// zero-width joiners) are dropped, control characters and line breaks
/// become spaces, runs of whitespace collapse, and the result is capped.
public enum AccountDisplayName {
    public static let maximumLength = 120

    /// The cleaned name, or nil when nothing visible is left.
    public static func sanitized(_ name: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.properties.generalCategory == .format { continue }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}
