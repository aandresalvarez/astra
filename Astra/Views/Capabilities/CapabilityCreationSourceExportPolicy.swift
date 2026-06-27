import Foundation

enum CapabilitySourceExportDirectoryState: Equatable {
    case resolving
    case resolved(URL)
    case unavailable

    var directory: URL? {
        guard case let .resolved(url) = self else { return nil }
        return url
    }

    var isTerminal: Bool {
        switch self {
        case .resolving:
            return false
        case .resolved, .unavailable:
            return true
        }
    }

    var canToggleSourceSaving: Bool {
        directory != nil
    }

    func saveToggleValue(saveSourceJSON: Bool) -> Bool {
        saveSourceJSON && directory != nil
    }

    var chipTitle: String {
        switch self {
        case .resolving:
            return "Locating source library"
        case let .resolved(url):
            return url.lastPathComponent
        case .unavailable:
            return "No source library"
        }
    }

    func validationLabel(saveSourceJSON: Bool) -> String {
        switch self {
        case .resolving:
            return "Resolving"
        case .resolved:
            return saveSourceJSON ? "Save" : "Skip"
        case .unavailable:
            return "Unavailable"
        }
    }
}

enum CapabilityCreationSourceExportPolicy {
    static func canCreate(
        hasRequiredContent: Bool,
        sourceState: CapabilitySourceExportDirectoryState
    ) -> Bool {
        hasRequiredContent && sourceState.isTerminal
    }
}
