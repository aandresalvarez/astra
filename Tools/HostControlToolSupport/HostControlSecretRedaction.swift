import Foundation

/// Redaction for everything the broker is about to hand back.
///
/// The rule this file implements: a value that reached the broker because it is
/// a credential must not leave it as text. That includes partial values — a
/// response capped mid-token still leaks the prefix — which is why the scan is
/// byte-level and truncation-boundary aware rather than a plain string replace.
///
/// It lives apart from `HostControlToolSupport.swift` because it is a closed
/// unit: the secret set comes from the connector manifest, the output is text,
/// and nothing else in the broker needs the machinery in between.
extension HostControlToolConfiguration {
    func redacted(_ value: String, includingSecretFragments: Bool = false) -> String {
        let secrets = secretValues
        let redacted = secrets.reduce(value) { current, secret in
            current.replacingOccurrences(of: secret, with: "[redacted]")
        }
        guard includingSecretFragments else { return redacted }
        return redactedSecretPrefixes(redacted, secrets: secrets)
    }

    private var secretValues: [String] {
        connectorManifest.connectors.flatMap { connector in
            connector.credentials.values.compactMap { envKey in
                guard isSecretKey(envKey),
                      let value = environment[envKey],
                      value.count >= 4 else { return nil }
                return value
            }
        }
    }

    private func isSecretKey(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper.contains("TOKEN")
            || upper.contains("SECRET")
            || upper.contains("PASSWORD")
            || upper.contains("API_KEY")
            || upper.contains("CREDENTIAL")
    }

    private func redactedSecretPrefixes(_ value: String, secrets: [String]) -> String {
        let redaction = Array("[redacted]".utf8)
        let source = Array(value.utf8)
        let ranges = mergedSecretPrefixRanges(in: source, secrets: secrets.map { Array($0.utf8) })
        guard !ranges.isEmpty else { return value }

        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var cursor = 0
        for range in ranges {
            guard range.lowerBound >= cursor else { continue }
            output.append(contentsOf: source[cursor..<range.lowerBound])
            output.append(contentsOf: redaction)
            cursor = range.upperBound
        }
        output.append(contentsOf: source[cursor..<source.count])
        return String(decoding: output, as: UTF8.self)
    }

    private func mergedSecretPrefixRanges(in value: [UInt8], secrets: [[UInt8]]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let boundaries = truncatedOutputBoundaries(in: value)
        for secret in secrets where secret.count >= 4 {
            appendShortTruncatedSecretPrefixRanges(in: value, secret: secret, boundaries: boundaries, to: &ranges)

            var index = 0
            while index + 4 <= value.count {
                guard value[index] == secret[0],
                      value[index + 1] == secret[1],
                      value[index + 2] == secret[2],
                      value[index + 3] == secret[3] else {
                    index += 1
                    continue
                }

                let maximumLength = min(secret.count, value.count - index)
                var length = 4
                while length < maximumLength, value[index + length] == secret[length] {
                    length += 1
                }
                ranges.append(index..<index + length)
                index += length
            }
        }

        guard !ranges.isEmpty else { return [] }
        return ranges.sorted { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound ? lhs.upperBound < rhs.upperBound : lhs.lowerBound < rhs.lowerBound
        }.reduce(into: []) { merged, range in
            guard let last = merged.last else {
                merged.append(range)
                return
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }

    private func appendShortTruncatedSecretPrefixRanges(
        in value: [UInt8],
        secret: [UInt8],
        boundaries: [Int],
        to ranges: inout [Range<Int>]
    ) {
        guard !value.isEmpty else { return }
        let maximumShortPrefixLength = min(3, secret.count)
        for boundary in boundaries {
            let candidateMaximumLength = min(maximumShortPrefixLength, boundary)
            for length in stride(from: candidateMaximumLength, through: 1, by: -1) {
                let start = boundary - length
                guard bytes(in: value, at: start, matchPrefixOf: secret, length: length) else { continue }
                let range = start..<boundary
                ranges.append(range)
                break
            }
        }
    }

    private func truncatedOutputBoundaries(in value: [UInt8]) -> [Int] {
        var boundaries = [value.count]
        let markerPrefix = Array("\n[ASTRA ".utf8)
        guard value.count >= markerPrefix.count else { return boundaries }
        for index in 0...(value.count - markerPrefix.count) where isTruncatedOutputMarker(in: value, at: index) {
            boundaries.append(index)
        }
        return boundaries
    }

    private func isTruncatedOutputMarker(in value: [UInt8], at index: Int) -> Bool {
        let truncatedMarker = Array("\n[ASTRA truncated ".utf8)
        if bytes(in: value, at: index, match: truncatedMarker) {
            return true
        }

        let cappedMarkerPrefix = Array("\n[ASTRA ".utf8)
        guard bytes(in: value, at: index, match: cappedMarkerPrefix) else { return false }

        let cappedNeedle = Array(" output capped after ".utf8)
        var cursor = index + cappedMarkerPrefix.count
        while cursor + cappedNeedle.count <= value.count {
            if value[cursor] == 10 {
                return false
            }
            if bytes(in: value, at: cursor, match: cappedNeedle) {
                return true
            }
            cursor += 1
        }
        return false
    }

    private func bytes(in value: [UInt8], at index: Int, match marker: [UInt8]) -> Bool {
        guard index >= 0, index + marker.count <= value.count else { return false }
        for offset in marker.indices where value[index + offset] != marker[offset] {
            return false
        }
        return true
    }

    private func bytes(in value: [UInt8], at index: Int, matchPrefixOf secret: [UInt8], length: Int) -> Bool {
        guard index >= 0, length <= secret.count, index + length <= value.count else { return false }
        for offset in 0..<length where value[index + offset] != secret[offset] {
            return false
        }
        return true
    }
}
