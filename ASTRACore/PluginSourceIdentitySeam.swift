import Foundation
import os

// Plugin sources (R5, T5): a workspace mirror records which source each
// plugin activation's copy came from, so a chosen file imported elsewhere
// enables an activation only where the same source installed that copy.
// The mirror is written in ASTRAPersistence; where a copy came from is the
// app's plugin source store (`PluginSources/provenance.json`), so the
// export asks through this seam. Same registration pattern as
// `TaskGeneratedFileQuerySeam`, wired from
// `RuntimeSeamRegistration.registerAll()`.
public protocol PluginSourceIdentityResolving: Sendable {
    /// `plugin-source:<id>` when the copy of `pluginID` with `digest` was
    /// installed by that source, nil when it is local.
    static func mirrorIdentity(pluginID: String, digest: String) -> String?
}

public enum PluginSourceIdentitySeam {
    private static let storage = OSAllocatedUnfairLock<(any PluginSourceIdentityResolving.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`.
    public static func register(_ provider: any PluginSourceIdentityResolving.Type) {
        storage.withLock { $0 = provider }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any PluginSourceIdentityResolving.Type {
        guard let provider = storage.withLock({ $0 }) else {
            preconditionFailure(
                "PluginSourceIdentitySeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return provider
    }
}
