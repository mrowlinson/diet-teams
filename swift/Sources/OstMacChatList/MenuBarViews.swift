// MenuBarViews.swift — top10-menubar: menu-bar extra content.
//
// MenuBarLabelView: presence dot + unread count (the menu-bar face).
// MenuBarPopoverView: quick-chat popover — own status, top unread rows
// (tap opens the chat in the main window), Open + Quit actions.
//
// The chats VM is snapshotted on appear (AppState rebuilds it on
// account switch; the popover re-snaps every open, so it never holds
// a stale list for long).
import DietDesign
import OstMacCore
import SwiftUI

/// Menu-bar face: own-presence dot + unread count (dot only at zero).
public struct MenuBarLabelView: View {
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var presence: PresenceStore

    public init(unread: UnreadStore, presence: PresenceStore) {
        self.unread = unread
        self.presence = presence
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(PresenceFormat.color(
                    availability: presence.own?.availability ?? "Offline"))
                .frame(width: 8, height: 8)
            if let text = MenuBarFormat.labelText(forTotal: unread.total) {
                Text(text)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textPrimaryColor)
            }
        }
        .accessibilityLabel(
            "Better Teams, \(presence.own?.availability ?? "Offline"), \(unread.total) unread")
    }
}

/// Quick-chat popover: status + top unread rows + Open/Quit.
public struct MenuBarPopoverView: View {
    private let chatsSource: () -> ChatListViewModel
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var presence: PresenceStore
    private let onOpenChat: (String) -> Void
    private let onOpenMain: () -> Void
    private let onQuit: () -> Void
    @State private var chats: ChatListViewModel?

    public init(
        chatsSource: @escaping () -> ChatListViewModel,
        unread: UnreadStore,
        presence: PresenceStore,
        onOpenChat: @escaping (String) -> Void,
        onOpenMain: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.chatsSource = chatsSource
        self.unread = unread
        self.presence = presence
        self.onOpenChat = onOpenChat
        self.onOpenMain = onOpenMain
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            HStack(spacing: DietSpace.xs) {
                Circle()
                    .fill(PresenceFormat.color(
                        availability: presence.own?.availability ?? "Offline"))
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                Spacer()
                Text("\(unread.total) unread")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            Divider()
            if let chats {
                MenuBarUnreadRows(
                    chats: chats, unread: unread, onOpenChat: onOpenChat)
            }
            Divider()
            HStack {
                Button("Open Better Teams", action: onOpenMain)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.link)
            }
        }
        .padding(DietSpace.md)
        .frame(width: 300)
        .onAppear { chats = chatsSource() }
    }

    private var statusText: String {
        if let own = presence.own {
            return PresenceFormat.label(
                availability: own.availability, activity: own.activity)
        }
        return "Offline"
    }
}

/// Unread rows (inner view so the snapshotted VM stays observed).
private struct MenuBarUnreadRows: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    let onOpenChat: (String) -> Void

    var body: some View {
        let rows = MenuBarFormat.unreadRows(
            chats: chats.chats, counts: unread.counts,
            overrides: unread.overrides)
        if rows.isEmpty {
            Text("You're all caught up.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        } else {
            ForEach(rows, id: \.chatID) { row in
                Button {
                    onOpenChat(row.chatID)
                } label: {
                    HStack {
                        Text(row.name)
                            .font(DietType.body)
                            .foregroundStyle(DietColor.textPrimaryColor)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.count)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
