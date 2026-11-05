import Foundation
import os

/// A read-only definition lookup for mirrors written by ASTRAPersistence.
/// Nil means unknown; an empty array proves that the accepted definition has
/// no skill, connector or local-tool credential namespaces. Version alone is
/// insufficient: the resolver must also match the recorded definition digest.
public protocol PluginCredentialComponentInventoryResolving: Sendable {
    static func componentIDs(pluginID: String, version: String, digest: String) -> [String]?
}

public enum PluginCredentialComponentInventorySeam {
    private static let storage = OSAllocatedUnfairLock<(any PluginCredentialComponentInventoryResolving.Type)?>(initialState: nil)

    public static func register(_ resolver: any PluginCredentialComponentInventoryResolving.Type) {
        storage.withLock { $0 = resolver }
    }

    public static func componentIDs(pluginID: String, version: String, digest: String) -> [String]? {
        storage.withLock { $0 }?.componentIDs(pluginID: pluginID, version: version, digest: digest)
    }
}
