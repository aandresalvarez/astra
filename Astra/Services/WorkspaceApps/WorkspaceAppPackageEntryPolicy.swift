import Foundation

enum WorkspaceAppPackageEntryPolicy {
    static func includesInResourceValidation(
        isDirectory: Bool?,
        isSymbolicLink: Bool?
    ) -> Bool {
        guard isDirectory == true else {
            return true
        }
        return isSymbolicLink == true
    }
}
