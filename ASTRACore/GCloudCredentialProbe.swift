import Foundation

/// Recognizes explicit credential failures from the read-only refresh probe.
/// Network failures, cancellation and silence do not prove a signed-out account.
enum GCloudCredentialProbe {
    static func authenticationFailure(binary: String, arguments: [String], stderr: String) -> String? {
        guard (binary as NSString).lastPathComponent == "gcloud",
              arguments == CommonCLIPrerequisites.gcloudAuth.livenessArgs else { return nil }
        let diagnostic = stderr.lowercased()
        if diagnostic.contains("you do not currently have an active account selected") {
            return "No active Google Cloud account is selected"
        }
        if diagnostic.contains("invalid_grant") || diagnostic.contains("reauthentication is needed")
            || diagnostic.contains("reauthentication failed") {
            return "Google Cloud credentials need to be renewed"
        }
        return nil
    }
}
