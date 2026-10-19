import Foundation
import ASTRACore

/// The one place a source plugin's display text is made safe to show (T14).
/// A name, author or description from a source is untrusted: a line break
/// could fake a row or heading, and a bidi control (U+202A–U+202E,
/// U+2066–U+2069, U+200E/F, U+061C) could reorder what the review sheet and
/// the Sources list claim. `PluginSourceCatalog` runs every listed entry
/// through here before its digest is taken.
///
/// IDs are never touched: they are validated separately, and an entry whose
/// text changed has a problem, so it offers no Add and no identity derived
/// from a cleaned name reaches the library.
enum PluginSourceDisplayText {
    /// Names, authors, categories and tags.
    static let nameLimit = 120
    /// Descriptions and summaries: the Agent Skills limit for a description.
    static let textLimit = 1_024

    enum Change: Equatable {
        case controlCharacters
        case shortened

        var problem: String {
            switch self {
            case .controlCharacters: "Display text changed: control characters removed"
            case .shortened: "Display text changed: long text shortened"
            }
        }
    }

    /// `text` on one line: control, format (Unicode `Cf`, bidi included) and
    /// line or paragraph separators removed, a line break or tab becoming a
    /// space, every whitespace run one space, the ends trimmed, and at most
    /// `limit` characters ending in an ellipsis. Spacing alone is no change;
    /// a removed character or a cut is.
    static func clean(_ text: String, limit: Int) -> (text: String, change: Change?) {
        var scalars = String.UnicodeScalarView()
        var removed = false
        var space = false
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                removed = true
                if scalar.properties.isWhitespace { space = true }
            case .spaceSeparator:
                space = true
            default:
                if space, !scalars.isEmpty { scalars.append(" ") }
                space = false
                scalars.append(scalar)
            }
        }
        var cleaned = String(scalars)
        var shortened = false
        if cleaned.count > limit {
            cleaned = String(cleaned.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
            shortened = true
        }
        return (cleaned, removed ? .controlCharacters : shortened ? .shortened : nil)
    }

    /// Cleans every display field of `package` in place: its name, author,
    /// description, category and tags, and each component's name and
    /// summary. Returns the first change, the one the entry reports.
    static func clean(_ package: inout PluginPackage) -> Change? {
        var changes: [Change] = []
        func name(_ value: inout String) { apply(&value, limit: nameLimit, into: &changes) }
        func text(_ value: inout String) { apply(&value, limit: textLimit, into: &changes) }
        name(&package.name)
        name(&package.author)
        text(&package.description)
        name(&package.category)
        for index in package.tags.indices { name(&package.tags[index]) }
        for index in package.skills.indices {
            name(&package.skills[index].name)
            text(&package.skills[index].description)
        }
        for index in package.connectors.indices {
            name(&package.connectors[index].name)
            text(&package.connectors[index].description)
        }
        for index in package.localTools.indices {
            name(&package.localTools[index].name)
            text(&package.localTools[index].description)
        }
        for index in package.mcpServers.indices { name(&package.mcpServers[index].displayName) }
        for index in package.templates.indices {
            name(&package.templates[index].name)
            text(&package.templates[index].description)
        }
        for index in package.setupRequirements.indices {
            name(&package.setupRequirements[index].displayName)
            text(&package.setupRequirements[index].notes)
        }
        return changes.first { $0 == .controlCharacters } ?? changes.first
    }

    private static func apply(_ value: inout String, limit: Int, into changes: inout [Change]) {
        let result = clean(value, limit: limit)
        value = result.text
        if let change = result.change { changes.append(change) }
    }
}
