import SwiftUI
import ASTRACore

// MARK: - Environment injection

private struct PreflightCacheKey: EnvironmentKey {
    /// Shared default so any view that doesn't explicitly inject one still
    /// gets a working (and cache-reusing, since it's static) cache.
    static let defaultValue: PreflightCache = PreflightCache()
}

extension EnvironmentValues {
    /// App-wide preflight cache. Keep one instance per app run so every
    /// catalog/wizard/settings view shares hits.
    var preflightCache: PreflightCache {
        get { self[PreflightCacheKey.self] }
        set { self[PreflightCacheKey.self] = newValue }
    }
}
