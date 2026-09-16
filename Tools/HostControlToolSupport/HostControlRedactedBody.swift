import Foundation

/// Caps an HTTP response body without letting the cap reintroduce a secret.
///
/// Capping and redacting interact: truncation can slice a credential so that
/// the exact-value pass no longer matches the remaining prefix, and the second
/// redaction pass can shorten the text enough that a different byte lands on
/// the boundary. So the sequence runs to a fixed point — cap, redact fragments,
/// re-cap, redact again — and only reports the result once redaction stops
/// changing it.
///
/// Extracted from the Jira response path so every brokered service gets the
/// same treatment. This is the kind of logic that quietly diverges when it is
/// copied per service, and the divergence is a leak.
enum HostControlRedactedBody {
    static func capped(
        _ value: String,
        label: String,
        byteLimit: Int,
        configuration: HostControlToolConfiguration,
        includeSecretFragments: Bool
    ) -> HostControlCappedOutput {
        let limit = max(1, byteLimit)
        let capped = HostControlOutputCap.capped(value, label: "redacted \(label)", byteLimit: limit)
        guard includeSecretFragments || capped.truncated else { return capped }

        let redactedAfterCap = configuration.redacted(capped.value, includingSecretFragments: true)
        let recapped = HostControlOutputCap.capped(redactedAfterCap, label: "redacted \(label)", byteLimit: limit)
        let finalValue = configuration.redacted(recapped.value, includingSecretFragments: true)
        if finalValue == recapped.value {
            return HostControlCappedOutput(value: recapped.value, truncated: capped.truncated || recapped.truncated)
        }

        let finalCap = HostControlOutputCap.capped(finalValue, label: "redacted \(label)", byteLimit: limit)
        return HostControlCappedOutput(
            value: finalCap.value,
            truncated: capped.truncated || recapped.truncated || finalCap.truncated
        )
    }
}
