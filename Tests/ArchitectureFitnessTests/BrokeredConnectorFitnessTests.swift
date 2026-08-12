import Foundation
import Testing

/// The rule these tests defend: a connector whose credentials are read inside
/// the host-control broker must not also have those credentials projected into
/// the agent's environment.
///
/// It was violated in production. `brokerOwnsConnectorConfiguration` was a
/// hard-coded `== "jira"`, so Jira was brokered and stripped while every other
/// connector — REDCap included — kept handing its token to the agent as an
/// environment variable. Nothing failed when that drifted, because the strip
/// list lived in the app and the handlers lived in the broker and neither knew
/// about the other. These tests are the thing that now fails.
///
/// This target deliberately has no package dependencies, so everything here is
/// a source scan. The runtime half of the invariant — registry against
/// `knownToolNames`, against the projection's tool list, against
/// `brokerOwnsConnectorConfiguration` — lives in
/// `Tests/BrokeredConnectorRegistryTests.swift`.
@Suite("Brokered connector fitness")
struct BrokeredConnectorFitnessTests {
    private static let registryPath = "Tools/HostControlToolSupport/HostControlBrokeredServices.swift"

    @Test("Ownership is read from the registry, not restated in the app")
    func ownershipIsReadFromTheRegistry() throws {
        let source = try fileText("Astra/Services/Runtime/HostControlPlaneMCPProjection.swift")
        let body = try functionBody(named: "brokerOwnsConnectorConfiguration", in: source)

        #expect(
            body.range(of: #""[a-z_]+""#, options: .regularExpression) == nil,
            """
            brokerOwnsConnectorConfiguration names a service type directly: \(body)
            It must delegate to HostControlBrokeredServices so a new handler cannot \
            be added without stripping the credential.
            """
        )
        #expect(body.contains("HostControlBrokeredServices"))
    }

    /// The structural guard. Anything that filters the manifest itself has
    /// bypassed the registry, and would keep working while the app went on
    /// projecting the credential.
    @Test("Broker connector lookups go through the registry")
    func brokerConnectorLookupsGoThroughTheRegistry() throws {
        let root = try repositoryRoot()
        // The redaction sweep in HostControlToolConfiguration deliberately walks
        // every connector, brokered or not: it has to redact secrets belonging
        // to connectors this broker has no typed handler for.
        let allowedLines: Set<String> = [
            "connectorManifest.connectors.flatMap { connector in"
        ]

        let violations = try swiftFiles(under: root.appendingPathComponent("Tools/HostControlToolSupport"))
            .filter { $0.lastPathComponent != "HostControlBrokeredServices.swift" }
            .flatMap { file -> [String] in
                let name = file.lastPathComponent
                return try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { index, line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.contains("connectorManifest.connectors"),
                              !allowedLines.contains(trimmed) else {
                            return nil
                        }
                        return "\(name):\(index + 1): \(trimmed)"
                    }
            }

        #expect(
            violations.isEmpty,
            """
            Broker code must reach connectors through \
            HostControlBrokeredServices.connector(forServiceType:alias:in:), which \
            refuses service types that are not also stripped from the agent's \
            environment: \(violations)
            """
        )
    }

    /// Catches the new-file case directly: a typed policy declares the service
    /// it speaks for, and that declaration has to appear in the registry.
    @Test("Every typed broker policy is registered")
    func everyTypedBrokerPolicyIsRegistered() throws {
        let root = try repositoryRoot()
        let registry = try fileText(Self.registryPath)
        let registered = Set(matches(of: #""([a-z0-9_-]+)"\s*:\s*""#, in: registry, group: 1))
        #expect(!registered.isEmpty, "Could not read any service types out of \(Self.registryPath)")

        var unregistered: [String] = []
        for file in try swiftFiles(under: root.appendingPathComponent("Tools/HostControlToolSupport")) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let declared = matches(
                of: #"static let serviceType\s*=\s*"([a-z0-9_-]+)""#,
                in: text,
                group: 1
            )
            for serviceType in declared where !registered.contains(serviceType) {
                unregistered.append("\(file.lastPathComponent): \(serviceType)")
            }
        }

        #expect(
            unregistered.isEmpty,
            """
            A typed broker handler declares a service type that is missing from \
            HostControlBrokeredServices, so the app is still projecting that \
            connector's credentials into the agent: \(unregistered)
            """
        )
    }

    // MARK: - Helpers

    private func functionBody(named name: String, in source: String) throws -> String {
        guard let start = source.range(of: "static func \(name)(") else {
            throw BrokeredConnectorFitnessError.declarationNotFound(name)
        }
        let remainder = source[start.upperBound...]
        guard let end = remainder.range(of: "\n    }") else {
            throw BrokeredConnectorFitnessError.declarationNotFound("\(name) body")
        }
        return String(remainder[..<end.lowerBound])
    }

    private func matches(of pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: group), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private func fileText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw BrokeredConnectorFitnessError.repositoryRootNotFound(FileManager.default.currentDirectoryPath)
            }
            candidate = parent
        }
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}

private enum BrokeredConnectorFitnessError: LocalizedError {
    case repositoryRootNotFound(String)
    case declarationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .repositoryRootNotFound(let path):
            return "Could not find the repository root from \(path)"
        case .declarationNotFound(let name):
            return "Could not find \(name) in the source"
        }
    }
}
