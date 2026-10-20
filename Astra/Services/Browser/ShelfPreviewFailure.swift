import Foundation
import ASTRACore

enum ShelfPreviewFailure: String, Equatable, Sendable {
    case tooLarge = "too_large"
    case missing
    case permissionDenied = "permission_denied"
    case decodeFailed = "decode_failed"
    case unsupported
    case readFailed = "read_failed"

    static func classify(_ error: Error) -> Self {
        if error is HostFileAccessError { return .permissionDenied }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return .missing }
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return .permissionDenied }
            if error.code == NSFileReadInapplicableStringEncodingError || error.code == NSFileReadCorruptFileError { return .decodeFailed }
        }
        if error.domain == NSPOSIXErrorDomain {
            if [Int(ENOENT), Int(ENOTDIR)].contains(error.code) { return .missing }
            if [Int(EACCES), Int(EPERM)].contains(error.code) { return .permissionDenied }
        }
        return .readFailed
    }
}
