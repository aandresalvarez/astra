import Foundation

struct WorkspaceAppStudioCommandPresentation: Equatable {
    let studioTitle: String
    let studioSubtitle: String
    let previewTitle: String
    let previewSubtitle: String
    let seedSampleDataTitle: String
    let closeDraftTitle: String
    let publishTitle: String
    let previewResetSampleDataTitle: String
    let previewCompletionTitle: String?

    init(appName: String?, workspaceName: String) {
        let trimmedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedWorkspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAppName.isEmpty {
            studioTitle = "App Studio"
            studioSubtitle = "\(trimmedWorkspaceName.isEmpty ? "Workspace" : trimmedWorkspaceName) · Draft"
        } else {
            studioTitle = trimmedAppName
            studioSubtitle = "Draft · Preview sandbox"
        }
        previewTitle = "Live Preview"
        previewSubtitle = "Sandbox · not published"
        seedSampleDataTitle = "Seed data"
        closeDraftTitle = "Close draft"
        publishTitle = "Publish"
        previewResetSampleDataTitle = "Reset sample data"
        previewCompletionTitle = nil
    }
}
