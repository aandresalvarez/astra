import Foundation

/// Identifies composer attachments that live in the per-user temporary
/// directory: pasted text and images (`astra_paste_*`) and dropped images
/// (`astra_drop_*`).
///
/// macOS reclaims that directory on its own schedule — files left unaccessed
/// for three days disappear, and APFS does not refresh access time on reads,
/// so in practice a paste vanishes three days after it was made. Such a path
/// is therefore never safe to keep in a task for life. `TaskInputMaterializer`
/// copies these into the task folder at first launch, and everything
/// downstream treats one that is already gone as a recoverable gap rather
/// than a launch-blocking contract violation.
public enum EphemeralComposerAttachment {
    public static let pastePrefix = "astra_paste_"
    public static let dropPrefix = "astra_drop_"

    /// Whether `path` names an ASTRA composer temp attachment sitting directly
    /// inside the system temporary directory. Symlinks are resolved on both
    /// sides so the `/var/…` and `/private/var/…` spellings compare equal.
    /// Prose inputs, relative paths, and ordinary user files are never
    /// ephemeral, even if they happen to live in the temporary directory.
    public static func isEphemeralPath(
        _ path: String,
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let name = (trimmed as NSString).lastPathComponent
        guard name.hasPrefix(pastePrefix) || name.hasPrefix(dropPrefix) else { return false }

        let resolvedParent = (resolved(trimmed) as NSString).deletingLastPathComponent
        return resolvedParent == resolved(temporaryDirectory)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
