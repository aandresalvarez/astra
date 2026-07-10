import SwiftUI

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

struct ShelfFileNavigatorHeader: View {
    @Binding var searchText: String
    @Binding var scope: ShelfFileNavigatorScope
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

                if showsScopePicker {
                    scopeMenu
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Stanford.cardBackground.opacity(0.45))
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
            Label(effectiveScope.label, systemImage: "line.3.horizontal.decrease.circle")
                .font(Stanford.caption(11).weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            .foregroundStyle(isActive ? Stanford.lagunita : Color.primary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isActive ? Stanford.lagunita.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return isActive ? Stanford.lagunita.opacity(0.16) : Color.primary.opacity(0.10)
        }
        return isActive ? Stanford.lagunita.opacity(0.10) : Color.clear
    }
}
