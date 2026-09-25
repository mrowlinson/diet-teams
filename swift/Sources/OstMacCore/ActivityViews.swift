// ActivityViews.swift — e1-activity: feed + mentions-center views.
//
// One shared row (ActivityRow) over two views: ActivityFeedView (all
// unreviewed kinds) and MentionsCenterView (owner mentions + channel
// blasts). Native List, stable row ids, diffed updates — no spinners,
// skeletons, or list jumps (zero-refresh rule). Rows show actor (never
// for reactions — unknown by design), chat name, snippet (preview-off
// redacted), and time. Tap jumps to the message; rows without a target
// (threadless missed calls) are inert, never conjure.
import DietDesign
import Foundation
import SwiftUI

/// Shared feed row: kind icon, title/actor + chat, snippet, time.
public struct ActivityRow: View {
    private let item: ActivityItem
    private let showPreview: Bool
    private let onJump: (ActivityTarget) -> Void
    private let onReviewed: (ActivityItem) -> Void

    public init(
        item: ActivityItem, showPreview: Bool,
        onJump: @escaping (ActivityTarget) -> Void,
        onReviewed: @escaping (ActivityItem) -> Void
    ) {
        self.item = item
        self.showPreview = showPreview
        self.onJump = onJump
        self.onReviewed = onReviewed
    }

    public var body: some View {
        Button {
            let target = ActivityTarget(
                chatID: item.chatID, messageID: item.messageID)
            guard target.canJump else { return }
            onJump(target)
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .frame(width: DietSize.iconLG)
                    .accessibilityLabel(item.kind.label)
                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                    HStack(spacing: DietSpace.xs) {
                        Text(item.rowTitle)
                            .font(DietType.headline)
                            .foregroundStyle(DietColor.textPrimaryColor)
                            .lineLimit(1)
                        if !item.chatName.isEmpty {
                            Text("in \(item.chatName)")
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                                .lineLimit(1)
                        }
                    }
                    Text(ActivityItem.displaySnippet(item, showPreview: showPreview))
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(2)
                }
                Spacer()
                Text(item.displayTime)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            .padding(.vertical, DietSpace.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainFocusRing()
        .disabled(!ActivityTarget(
            chatID: item.chatID, messageID: item.messageID).canJump)
        .contextMenu {
            Button("Mark Reviewed") { onReviewed(item) }
        }
        .accessibilityIdentifier("activity-\(item.id)")
    }
}

/// In-app notification history: mentions, replies, reactions, missed
/// calls, newest first. Empty store shows named guidance, never blank.
public struct ActivityFeedView: View {
    @ObservedObject public var store: ActivityStore
    private let showPreview: Bool
    private let onJump: (ActivityTarget) -> Void

    public init(
        store: ActivityStore, showPreview: Bool = true,
        onJump: @escaping (ActivityTarget) -> Void = { _ in }
    ) {
        self.store = store
        self.showPreview = showPreview
        self.onJump = onJump
    }

    public static let emptyImage = "bell"
    public static let emptyTitle = "No new activity"
    public static let emptyMessage =
        "Mentions, replies, reactions, and missed calls will appear here."

    public var body: some View {
        Group {
            if store.visibleItems.isEmpty {
                DietEmptyState(
                    systemImage: Self.emptyImage,
                    title: Self.emptyTitle,
                    message: Self.emptyMessage)
            } else {
                List(store.visibleItems) { item in
                    ActivityRow(
                        item: item, showPreview: showPreview,
                        onJump: onJump,
                        onReviewed: { store.markReviewed(id: $0.id) })
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Mark All Reviewed") { store.markAllReviewed() }
                    .disabled(store.visibleItems.isEmpty)
                    .help("Dismiss every activity item")
            }
        }
        .frame(minWidth: 320, minHeight: 300)
    }
}

/// Every owner @-mention across chats AND channels: owner hits plus
/// channel blasts, newest first. Reviewing here clears the
/// MentionStore flag (shared data, no orphans).
public struct MentionsCenterView: View {
    @ObservedObject public var store: ActivityStore
    private let showPreview: Bool
    private let onJump: (ActivityTarget) -> Void

    public init(
        store: ActivityStore, showPreview: Bool = true,
        onJump: @escaping (ActivityTarget) -> Void = { _ in }
    ) {
        self.store = store
        self.showPreview = showPreview
        self.onJump = onJump
    }

    public static let emptyImage = "at"
    public static let emptyTitle = "No mentions"
    public static let emptyMessage =
        "Every time someone mentions you — in any chat or channel — it lands here for review."

    public var body: some View {
        Group {
            if store.mentionItems.isEmpty {
                DietEmptyState(
                    systemImage: Self.emptyImage,
                    title: Self.emptyTitle,
                    message: Self.emptyMessage)
            } else {
                List(store.mentionItems) { item in
                    ActivityRow(
                        item: item, showPreview: showPreview,
                        onJump: onJump,
                        onReviewed: { store.markReviewed(id: $0.id) })
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Mentions")
        .frame(minWidth: 320, minHeight: 300)
    }
}
