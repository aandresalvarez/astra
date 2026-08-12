import Foundation
import Testing
@testable import HostControlToolSupport

/// Companion to `Tools/HostControlToolSupport/HostControlSecretRedaction.swift`.
///
/// The behavioural coverage for redaction lives with the tools that produce the
/// text being redacted, in `HostControlToolSupportTests`. What is here is the
/// part that behaviour cannot express: the prefix scan has to stay bounded to
/// truncation boundaries, because the obvious implementation — check every
/// offset for every short prefix of every secret — is quadratic on output the
/// broker is already streaming.
@Suite("Host control secret redaction")
struct HostControlSecretRedactionTests {
    @Test("Short secret prefix scan only checks truncation boundaries")
    func shortSecretPrefixScanOnlyChecksTruncationBoundaries() throws {
        let source = try redactionSource()
        let prefixScan = try snippet(
            startingWith: "    private func mergedSecretPrefixRanges(",
            endingBefore: "    private func bytes(in value: [UInt8], at index: Int, match marker",
            in: source
        )

        let boundaryScanCount = prefixScan.components(separatedBy: "truncatedOutputBoundaries(in: value)").count - 1
        #expect(boundaryScanCount == 1)
        #expect(prefixScan.contains("boundaries: boundaries"))
        #expect(prefixScan.contains("output capped after"))
        #expect(!prefixScan.contains("for index in value.indices"))
        #expect(!prefixScan.contains("Array(value[range])"))
        #expect(!prefixScan.contains("secret.prefix(length)"))
    }

    /// A redaction pass that runs before the secret set is known redacts
    /// nothing, so the secret set has to come from the manifest the broker was
    /// launched with rather than from a value passed in at the call site.
    @Test("The secret set is read from the connector manifest, not the caller")
    func secretSetIsReadFromTheConnectorManifest() throws {
        let connectors = """
        {"connectors":[{"id":"redcap-1","alias":"redcap","envPrefix":"REDCAP","name":"REDCap",\
        "serviceType":"redcap","baseURL":"https://redcap.example.test/api/","authMethod":"token",\
        "env":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},"credentials":{"REDCAP_API_TOKEN":"REDCAP_TOKEN_ENV"},\
        "config":{}}]}
        """
        let configuration = HostControlToolConfiguration(
            connectorsJSON: connectors,
            environment: ["REDCAP_TOKEN_ENV": "0123456789ABCDEF"]
        )

        #expect(configuration.redacted("token=0123456789ABCDEF&content=record")
            == "token=[redacted]&content=record")
    }

    // MARK: - Helpers

    private func redactionSource() throws -> String {
        try String(
            contentsOf: TestRepositoryRoot.resolve()
                .appendingPathComponent("Tools/HostControlToolSupport/HostControlSecretRedaction.swift"),
            encoding: .utf8
        )
    }

    private func snippet(startingWith start: String, endingBefore end: String, in source: String) throws -> String {
        let startIndex = try #require(source.range(of: start)?.lowerBound)
        let endIndex = try #require(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return String(source[startIndex..<endIndex])
    }
}
