import Foundation

extension ShelfID {
    init(workspaceCanvasItem: WorkspaceCanvasItem) {
        switch workspaceCanvasItem {
        case .plan:
            self = .plan
        case .markdown:
            self = .files
        case .browser:
            self = .browser
        case .query:
            self = .query
        case .appPreview:
            self = .appPreview
        }
    }

    var workspaceCanvasItem: WorkspaceCanvasItem {
        switch self {
        case .plan:
            .plan
        case .files:
            .markdown
        case .browser:
            .browser
        case .query:
            .query
        case .appPreview:
            .appPreview
        }
    }
}

extension WorkspaceCanvasItem {
    var shelfID: ShelfID {
        ShelfID(workspaceCanvasItem: self)
    }
}
