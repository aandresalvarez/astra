import Foundation
import ASTRAModels

/// Owns the one-time Files shelf discovery flag without making the SwiftUI view
/// another direct persistence owner.
enum ShelfFileNavigatorDiscoveryStore {
    static func hasDiscovered(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppStorageKeys.markdownShelfFileNavigatorDiscovered)
    }

    static func markDiscovered(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: AppStorageKeys.markdownShelfFileNavigatorDiscovered)
    }
}
