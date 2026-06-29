import Foundation
import ASTRACore

enum GoogleWorkspaceRemoteMCPProductID: String, CaseIterable, Equatable, Sendable {
    case gmail
    case drive
    case calendar
}

enum GoogleWorkspaceRemoteMCPToolFamily: String, Equatable, Sendable {
    case read
    case draft
    case label
    case write
    case delete
    case permissionRead
    case download
    case availabilityRead
    case response
}

struct GoogleWorkspaceRemoteMCPProduct: Equatable, Sendable {
    var id: GoogleWorkspaceRemoteMCPProductID
    var displayName: String
    var serverID: String
    var endpoint: URL
    var transport: PluginMCPServer.Transport
    var requiredAPIs: [String]
    var requiredScopes: [String]
    var documentedTools: [String]
    var toolFamilies: [String: GoogleWorkspaceRemoteMCPToolFamily]
    var documentationURL: URL
    var developerPreview: Bool
    var previewCaveat: String
}

enum GoogleWorkspaceRemoteMCPRegistry {
    static let products: [GoogleWorkspaceRemoteMCPProduct] = [
        gmail,
        drive,
        calendar
    ]

    static func product(_ id: GoogleWorkspaceRemoteMCPProductID) -> GoogleWorkspaceRemoteMCPProduct? {
        products.first { $0.id == id }
    }

    static func toolFamily(
        product id: GoogleWorkspaceRemoteMCPProductID,
        toolName: String
    ) -> GoogleWorkspaceRemoteMCPToolFamily? {
        product(id)?.toolFamilies[toolName]
    }

    private static let previewCaveat = "Google Workspace MCP servers are currently documented by Google as a preview surface; ASTRA must keep them behind the local gateway so OAuth, policy, and failure handling stay owned by ASTRA."

    private static let gmail = GoogleWorkspaceRemoteMCPProduct(
        id: .gmail,
        displayName: "Gmail",
        serverID: "google_workspace_gmail",
        endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!,
        transport: .http,
        requiredAPIs: ["Gmail API", "Gmail MCP API"],
        requiredScopes: [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose"
        ],
        documentedTools: [
            "create_draft",
            "get_thread",
            "label_message",
            "label_thread",
            "list_drafts",
            "list_labels",
            "search_threads",
            "unlabel_message",
            "unlabel_thread"
        ],
        toolFamilies: [
            "create_draft": .draft,
            "get_thread": .read,
            "label_message": .label,
            "label_thread": .label,
            "list_drafts": .read,
            "list_labels": .read,
            "search_threads": .read,
            "unlabel_message": .label,
            "unlabel_thread": .label
        ],
        documentationURL: URL(string: "https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server")!,
        developerPreview: true,
        previewCaveat: previewCaveat
    )

    private static let drive = GoogleWorkspaceRemoteMCPProduct(
        id: .drive,
        displayName: "Google Drive",
        serverID: "google_workspace_drive",
        endpoint: URL(string: "https://drivemcp.googleapis.com/mcp/v1")!,
        transport: .http,
        requiredAPIs: ["Google Drive API", "Google Drive MCP API"],
        requiredScopes: [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.file"
        ],
        documentedTools: [
            "copy_file",
            "create_file",
            "download_file_content",
            "get_file_metadata",
            "get_file_permissions",
            "list_recent_files",
            "read_file_content",
            "search_files"
        ],
        toolFamilies: [
            "copy_file": .write,
            "create_file": .write,
            "download_file_content": .download,
            "get_file_metadata": .read,
            "get_file_permissions": .permissionRead,
            "list_recent_files": .read,
            "read_file_content": .read,
            "search_files": .read
        ],
        documentationURL: URL(string: "https://developers.google.com/workspace/drive/api/guides/configure-mcp-server")!,
        developerPreview: true,
        previewCaveat: previewCaveat
    )

    private static let calendar = GoogleWorkspaceRemoteMCPProduct(
        id: .calendar,
        displayName: "Google Calendar",
        serverID: "google_workspace_calendar",
        endpoint: URL(string: "https://calendarmcp.googleapis.com/mcp/v1")!,
        transport: .http,
        requiredAPIs: ["Google Calendar API", "Google Calendar MCP API"],
        requiredScopes: [
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events.freebusy",
            "https://www.googleapis.com/auth/calendar.events.readonly"
        ],
        documentedTools: [
            "create_event",
            "delete_event",
            "get_event",
            "list_calendars",
            "list_events",
            "respond_to_event",
            "suggest_time",
            "update_event"
        ],
        toolFamilies: [
            "create_event": .write,
            "delete_event": .delete,
            "get_event": .read,
            "list_calendars": .read,
            "list_events": .read,
            "respond_to_event": .response,
            "suggest_time": .availabilityRead,
            "update_event": .write
        ],
        documentationURL: URL(string: "https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server")!,
        developerPreview: true,
        previewCaveat: previewCaveat
    )
}
