import SwiftUI
import ASTRAModels

enum ShelfFileNavigatorScope: String, CaseIterable, Identifiable {
    case task
    case workspace
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task: "This Task"
        case .workspace: "Workspace"
        case .all: "All"
        }
    }
}

/// How Browse files lists a task's files: as folders on disk, or by the turn
/// that created, edited, or removed them. Turns ignore the scope, since one
/// turn can touch task and workspace files alike.
enum ShelfFileNavigatorOrganization: String, CaseIterable, Identifiable {
    case folders
    case turns

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folders: "Folders"
        case .turns: "Turns"
        }
    }

    /// The last choice, read from `UserDefaults` directly, as
    /// `RailDisclosureStore` does, to keep off the AppStorage ratchet.
    static var stored: ShelfFileNavigatorOrganization {
        UserDefaults.standard.string(forKey: AppStorageKeys.markdownShelfFileNavigatorOrganization)
            .flatMap(Self.init(rawValue:)) ?? .folders
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: AppStorageKeys.markdownShelfFileNavigatorOrganization)
    }
}

enum ShelfFileNavigatorRootAvailability {
    /// Task scope intentionally treats workspace roots as an escape hatch when
    /// the task has no roots yet. Other scopes must describe their own paths so
    /// a task folder cannot mask missing workspace configuration.
    static func hasConfiguredRoots(
        allRootCount: Int,
        scopedRootCount: Int,
        scope: ShelfFileNavigatorScope
    ) -> Bool {
        switch scope {
        case .task:
            allRootCount > 0
        case .workspace, .all:
            scopedRootCount > 0
        }
    }
}

struct ShelfFileNavigatorHeader: View {
    @Binding var searchText: String
    @Binding var scope: ShelfFileNavigatorScope
    @Binding var organization: ShelfFileNavigatorOrganization
    @Binding var isPinned: Bool
    let effectiveScope: ShelfFileNavigatorScope
    let showsScopePicker: Bool
    let isScanning: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Browse files")
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 18, height: 18)
                }

                Button {
                    isPinned.toggle()
                } label: {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                        .font(Stanford.caption(11).weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isPinned ? Stanford.lagunita : .secondary)
                .help(isPinned ? "Let the file browser float" : "Keep the file browser open")
                .accessibilityIdentifier("FilesShelfPinBrowserButton")

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(Stanford.ui(11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh workspace files")
            }

            HStack(spacing: 7) {
                TextField("Search files by name or path", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.caption(12))
            }

            if showsScopePicker {
                Divider()

                HStack(spacing: 8) {
                    organizationPicker

                    if organization == .folders {
                        scopeMenu
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Stanford.cardBackground.opacity(0.45))
    }

    private var organizationPicker: some View {
        Picker("Organize files", selection: $organization) {
            ForEach(ShelfFileNavigatorOrganization.allCases) { candidate in
                Text(candidate.label).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .onChange(of: organization) { _, choice in choice.store() }
        .help("List files by folder, or by the turn that changed them")
        .accessibilityIdentifier("FilesShelfOrganizationPicker")
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(ShelfFileNavigatorScope.allCases) { candidate in
                Button {
                    scope = candidate
                } label: {
                    if effectiveScope == candidate {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: effectiveScope == .task ? "folder" : "folder.badge.gearshape")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)

                Text(effectiveScope.label)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(Stanford.ui(9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Choose which files to browse")
        .accessibilityIdentifier("FilesShelfScopeMenu")
    }
}

struct ShelfOpenDocumentsSection: View {
    @ObservedObject var session: ShelfMarkdownSession
    let onSelect: (String) -> Void

    var body: some View {
        if !session.documents.isEmpty {
            HStack(spacing: 6) {
                Label("Open", systemImage: "clock")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("\(session.documents.count)")
                    .font(Stanford.caption(10).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(session.documents) { document in
                let isSelected = session.selectedDocumentID == document.id
                Button {
                    onSelect(document.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: document.kind.systemImage)
                            .font(Stanford.ui(11, weight: .medium))
                            .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                            .frame(width: 16)

                        Text(document.title)
                            .font(Stanford.caption(12).weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Stanford.lagunita : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(isSelected ? Stanford.lagunita.opacity(0.10) : Color.clear)
                }
                .buttonStyle(.plain)
                .help(document.fileURL.path)
            }

            Divider()
                .padding(.vertical, 4)
        }
    }
}

struct BrowseFilesToolbarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Stanford.caption(12).weight(.semibold))
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Stanford.lagunita.opacity(isActive ? 0.28 : 0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Stanford.lagunita.opacity(0.16)
        }
        return Stanford.lagunita.opacity(isActive ? 0.12 : 0.07)
    }
}
