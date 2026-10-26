import Foundation

/// Enumeration has its own bound: even empty or unsupported files cost
/// directory work and memory. Readers stop before accumulating past it.
public enum PluginDirectoryEntries: Equatable, Sendable {
    case names([String])
    case tooLarge
}

public extension PluginDirectoryReading {
    /// Convenience for converters. A budgeted reader records an excess so
    /// the entire source is refused, never imported as a truncated listing.
    func entries(in relativeDirectory: String) -> [String] {
        guard case .names(let names) = entries(in: relativeDirectory, limit: PluginSourceLimits.totalDirectoryEntries)
        else { return [] }
        return names
    }
}
