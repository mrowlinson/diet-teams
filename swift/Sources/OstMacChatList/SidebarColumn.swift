// SidebarColumn.swift — sidebar column: Chats list + Teams browser switcher.
import OstMacCore
import SwiftUI

/// Sidebar column hosting the chats list and the teams/channels browser
/// behind a segmented switcher. Channel taps open as conversations via
/// `onOpenChannel` (channel id + "Team > #channel" display name).
public struct SidebarColumn: View {
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    private let openChatID: String?
    private let onOpenChannel: (String, String) -> Void
    @State private var section: SidebarSection

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        openChatID: String? = nil,
        initialSection: SidebarSection = .chats,
        onOpenChannel: @escaping (String, String) -> Void
    ) {
        self.chats = chats
        self.teams = teams
        self.openChatID = openChatID
        _section = State(initialValue: initialSection)
        self.onOpenChannel = onOpenChannel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                Text("Chats").tag(SidebarSection.chats)
                Text("Teams").tag(SidebarSection.teams)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch section {
            case .chats:
                ChatListSidebar(model: chats)
            case .teams:
                TeamsBrowser(model: teams, openChatID: openChatID, onOpen: onOpenChannel)
            }
        }
    }
}

public enum SidebarSection {
    case chats
    case teams
}
