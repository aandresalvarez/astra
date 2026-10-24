import Foundation
import ASTRACore

final class RuntimeSupervisionTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var stdout = ""
    private var stderr = ""
    private var errors = 0
    var text: String { lock.lock(); defer { lock.unlock() }; return tail }
    var stderrBytes: Int { lock.lock(); defer { lock.unlock() }; return errors }
    func append(_ text: String, stderr isError: Bool, taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        let secrets = Self.streamSpellings(RunSecretRedactionScope.secrets(for: taskID))
        if isError {
            errors += text.utf8.count
            stderr = Self.boundedRaw(stderr + text, secrets: secrets)
        } else {
            stdout = Self.boundedRaw(stdout + text, secrets: secrets)
        }
        // Preserve raw seams privately and independently: stderr can arrive in
        // the middle of a stdout secret. Only redacted projections leave here.
        let output = Self.redacted(stdout, secrets: secrets)
        let error = Self.redacted(stderr, secrets: secrets)
        tail = error.isEmpty ? String(output.suffix(1_200))
            : "stdout: \(output.suffix(580))\nstderr: \(error.suffix(580))"
    }

    private static func streamSpellings(_ secrets: [String]) -> [String] {
        var values = Set(secrets)
        let formats: [JSONEncoder.OutputFormatting] = [[], .withoutEscapingSlashes]
        // Provider stdout is often raw JSON, so multiline keys, quotes and
        // backslashes reach this boundary escaped rather than decoded.
        for secret in secrets {
            for format in formats {
                let encoder = JSONEncoder()
                encoder.outputFormatting = format
                if let data = try? encoder.encode(secret), let json = String(data: data, encoding: .utf8) {
                    values.insert(String(json.dropFirst().dropLast()))
                }
            }
        }
        return Array(values)
    }

    private static func boundedRaw(_ text: String, secrets: [String]) -> String {
        let limit = 1_200 + (secrets.map(\.count).max() ?? 0)
        guard text.count > limit else { return text }
        var cut = text.index(text.endIndex, offsetBy: -limit)
        // Never retain only the suffix of a credential crossing the eviction
        // boundary. Such a suffix cannot be recognized on the next append.
        var previousCut: String.Index
        repeat {
            previousCut = cut
            for secret in secrets where !secret.isEmpty {
                var start = text.startIndex
                while start < cut, let range = text.range(of: secret, range: start..<text.endIndex) {
                    if range.lowerBound < cut, range.upperBound > cut { cut = range.upperBound }
                    start = range.upperBound
                }
            }
        } while previousCut != cut
        return String(text[cut...])
    }

    private static func redacted(_ text: String, secrets: [String]) -> String {
        var value = RunSecretRedaction.redact(text, secrets: secrets)
        // Withhold even short pending prefixes until the next chunk disambiguates
        // them; the shared redactor intentionally only masks fragments >=8 bytes.
        var pending = 0
        for secret in secrets where secret.count >= RunSecretRedaction.minimumSecretLength {
            for length in 1..<min(secret.count, value.count + 1)
                where length > pending && value.hasSuffix(secret.prefix(length)) {
                pending = length
            }
        }
        if pending > 0 { value = String(value.dropLast(pending)) + RunSecretRedaction.marker }
        return value
    }
}
