import Foundation
import os

// Plugin sources (R5, T5): a workspace mirror records which source each
// plugin activation's copy came from, so a chosen file imported elsewhere
// enables an activation only where the same source installed that copy.
// The mirror is written in ASTRAPersistence; where a copy came from is the
// app's plugin source store (`PluginSources/provenance.json`), so the
// export asks through this seam. Same registration pattern as
// `TaskGeneratedFileQuerySeam`, except that it is not wired from
// `RuntimeSeamRegistration.registerAll()` (the test bootstrap runs that):
// only the app's launch path registers the real store, and until then every
// copy reads as local.
public protocol PluginSourceIdentityResolving: Sendable {
    /// `plugin-source:<id>` when the copy of `pluginID` with `digest` was
    /// installed by that source, nil when it is local.
    static func mirrorIdentity(pluginID: String, digest: String) -> String?
    /// The copy of `pluginID` installed now and where it came from; nil
    /// when nothing here can tell (no plugin source store).
    static func installedCopy(pluginID: String) -> PluginInstalledCopy?
}

extension PluginSourceIdentityResolving {
    public static func installedCopy(pluginID: String) -> PluginInstalledCopy? { nil }
}

/// The library's copy of a plugin, as the workspace mirror's source
/// identity names it (R5, T5).
public enum PluginInstalledCopy: Equatable, Sendable {
    case notInstalled
    /// `source` is `plugin-source:<id>`, or nil for a local copy.
    case installed(source: String?)

    /// The installed copy's source, nil when local or not installed.
    public var source: String? {
        if case .installed(let source) = self { return source }
        return nil
    }
}

public enum PluginSourceIdentitySeam {
    private static let storage = OSAllocatedUnfairLock<(any PluginSourceIdentityResolving.Type)?>(initialState: nil)

    /// Set once by the app's launch path (`PluginSourceStore.launchedApp`).
    public static func register(_ provider: any PluginSourceIdentityResolving.Type) {
        storage.withLock { $0 = provider }
    }

    /// The registered resolver, or `LocalPluginSourceIdentity` (every copy
    /// local) when none is: never a trap, and never the real store by
    /// default.
    public static var current: any PluginSourceIdentityResolving.Type {
        storage.withLock({ $0 }) ?? LocalPluginSourceIdentity.self
    }
}

/// Every copy is local: what the mirror records outside a launched app.
public enum LocalPluginSourceIdentity: PluginSourceIdentityResolving {
    public static func mirrorIdentity(pluginID: String, digest: String) -> String? { nil }
}
