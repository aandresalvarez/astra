import Foundation

/// A `UserDefaults` that keeps every value in memory and never reaches `cfprefsd`.
///
/// Tests that need to pin a preference without disturbing the developer's real
/// settings used to mint a throwaway suite per test:
///
///     let suiteName = "astra-agent-policy-sandbox-\(UUID().uuidString)"
///     let defaults = UserDefaults(suiteName: suiteName)!
///     defer { defaults.removePersistentDomain(forName: suiteName) }
///
/// That leaks one file per execution, permanently.
/// `removePersistentDomain(forName:)` only clears the domain's *keys* — it does
/// not unlink the backing plist, so `~/Library/Preferences/<suiteName>.plist`
/// survives as a 42-byte empty dictionary. Deleting the file from inside the
/// test does not help either: `cfprefsd` still holds the domain and writes it
/// back out after the test process exits. There is no in-process sequence of
/// `removePersistentDomain` / `removeSuite` / `unlink` that wins this race,
/// because the daemon's flush happens last.
///
/// So every `swift test` run left behind another batch of empty plists that
/// nothing would ever collect. A `~/Library/Preferences` holding tens of
/// thousands of them slows down everything that enumerates preference domains
/// — `defaults domains`, System Settings, login.
///
/// `InMemoryDefaults` sidesteps the persistence machinery rather than trying to
/// clean up after it. `UserDefaults`' typed accessors (`string(forKey:)`,
/// `bool(forKey:)`, `integer(forKey:)`, `url(forKey:)`, …) and its typed
/// setters all funnel through the three primitives overridden below, so a
/// dictionary is enough to back the whole API. No suite is registered, so
/// there is no domain to leak, no plist to sweep, and no teardown to forget.
///
/// Each instance is independent, which also makes it safe for the parallel
/// `@Test`s that previously had to avoid `.standard` to stay deterministic.
final class InMemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var storage: [String: Any]

    /// - Parameter initialValues: preferences to seed, as if already stored.
    init(_ initialValues: [String: Any] = [:]) {
        storage = initialValues
        // `suiteName: nil` yields the standard search list. Every accessor that
        // could consult it is overridden below, so the superclass store is
        // never read from or written to.
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: defaultName)
    }
}
