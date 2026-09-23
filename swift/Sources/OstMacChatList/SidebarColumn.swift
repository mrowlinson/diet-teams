// SidebarColumn.swift — sidebar column: Chats list + Teams browser switcher.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar column hosting the chats list, the teams/channels browser,
/// and the reminders browser behind a segmented switcher. Channel taps
/// open as conversations via `onOpenChannel` (channel id +
/// "Team > #channel" display name).
///
/// The switcher header is exactly `DietSize.toolbar` tall with a system
/// seam below, so it sits on the same pixel row as the content column's
/// `DietHeaderBar` seam (single divider language app-wide).
public struct SidebarColumn: View {
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    @ObservedObject private var reminders: RemindersViewModel
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    private let openChatID: String?
    private let initialFilter: String
    private let onOpenChannel: (String, String) -> Void
    @State private var section: SidebarSection

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        reminders: RemindersViewModel,
        presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        openChatID: String? = nil,
        initialSection: SidebarSection = .chats,
        initialFilter: String = "",
        onOpenChannel: @escaping (String, String) -> Void
    ) {
        self.chats = chats
        self.teams = teams
        self.reminders = reminders
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.openChatID = openChatID
        self.initialFilter = initialFilter
        _section = State(initialValue: initialSection)
        self.onOpenChannel = onOpenChannel
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietSegmentedPicker("Section", selection: $section)
                .padding(.horizontal, DietSpace.sm)
                .frame(height: DietSize.toolbar)
            DietSeamH()
            switch section {
            case .chats:
                ChatListSidebar(model: chats, presence: presence, unread: unread, mentions: mentions, initialFilter: initialFilter)
                    .transition(.opacity)
            case .teams:
                TeamsBrowser(
                    model: teams, openChatID: openChatID, unread: unread,
                    initialFilter: initialFilter, onOpen: onOpenChannel)
                    .transition(.opacity)
            case .reminders:
                RemindersBrowser(model: reminders)
                    .transition(.opacity)
            }
        }
        // System-default crossfade when the segmented switcher flips
        // sections. Standard SwiftUI only (no custom drivers).
        .animation(.default, value: section)
    }
}

public enum SidebarSection: String, CaseIterable {
    case chats = "Chats"
    case teams = "Teams"
    case reminders = "Reminders"
}
