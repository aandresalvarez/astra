import Foundation

/// The one `URLSessionConfiguration` every brokered host-control client builds
/// from, and the one place tests can divert those requests away from the
/// network.
///
/// It lives in its own file rather than inside `HostControlToolSupport.swift`
/// because it is the seam the whole module's HTTP goes through, and burying a
/// process-wide mutable registry two thousand lines into the tool handlers is
/// how it came to be treated as a plain variable.
enum HostControlURLSessionConfiguration {
    private static let lock = NSLock()
    private static var testingProtocolClasses: [AnyClass] = []

    /// Registration is additive on purpose. Several test suites stub host HTTP
    /// through this one process-wide list and they run concurrently, so a suite
    /// must be able to install and remove its own stub without being able to
    /// drop anybody else's. This used to be a settable array with that rule
    /// written in a comment on one of the call sites; a third suite arriving
    /// with a `= []` teardown unregistered another suite's stub mid-request,
    /// and the symptom was not a registration error but a real network attempt
    /// that failed as `status_code: 0`.
    static func registerTestingProtocolClass(_ protocolClass: AnyClass) {
        lock.lock()
        defer { lock.unlock() }
        guard !testingProtocolClasses.contains(where: {
            ObjectIdentifier($0) == ObjectIdentifier(protocolClass)
        }) else { return }
        testingProtocolClasses.append(protocolClass)
    }

    static func unregisterTestingProtocolClass(_ protocolClass: AnyClass) {
        lock.lock()
        defer { lock.unlock() }
        testingProtocolClasses.removeAll {
            ObjectIdentifier($0) == ObjectIdentifier(protocolClass)
        }
    }

    static func brokeredHTTPConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        lock.lock()
        let customProtocolClasses = testingProtocolClasses
        lock.unlock()
        if !customProtocolClasses.isEmpty {
            configuration.protocolClasses = customProtocolClasses + (configuration.protocolClasses ?? [])
        }
        return configuration
    }
}
