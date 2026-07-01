enum WorkspaceAppActionStatusPresentation {
    static func errorMessage(for error: any Error) -> String {
        error.localizedDescription
    }
}
