// OstMacRootView.swift — om-package lane: real app shell.
// Sidebar (chat list) + detail (conversation). Selection opens history;
// live Trouter events ingest into the open chat. --demo runs offline
// with canned rows + messages (no sign-in) for shots.
import AppKit
import OstMacChatList
import OstMacCore
import SwiftUI

public struct OstMacRootView: View {
    @StateObject private var chats: ChatListViewModel
    @StateObject private var conversation: ConversationStore
    @Environment(\.openWindow) private var openWindow
    private let demo: Bool

    public init(demo: Bool = false) {
        self.demo = demo
        if demo {
            let vm = ChatListViewModel(fetcher: { _ in
                ChatsResponse(ok: true, chats: DemoData.chats)
            })
            vm.selectedChatID = "demo"
            _chats = StateObject(wrappedValue: vm)
            _conversation = StateObject(wrappedValue: .demo())
        } else {
            _chats = StateObject(wrappedValue: ChatListViewModel())
            _conversation = StateObject(wrappedValue: ConversationStore())
        }
    }

    public var body: some View {
        NavigationSplitView {
            ChatListSidebar(model: chats)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            if conversation.chatID == nil {
                ContentUnavailableView(
                    "Select a chat",
                    systemImage: "bubble.left.and.bubble.right")
            } else {
                ConversationView(store: conversation)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: chats.selectedChatID) { _, newID in
            guard let id = newID, id != conversation.chatID else { return }
            conversation.open(chatID: id, chatName: chats.selectedChat?.name)
        }
        .onAppear {
            // Shot hooks: open secondary windows from launch args.
            let args = CommandLine.arguments
            // Shot hook: Settings opens via its menu item (no public API).
            if args.contains("--show-about") { openWindow(id: AppIdentity.aboutWindowID) }
        }
        .task {
            _ = RustCore.initialize()
            await chats.load()
            await runLive()
        }
        .onDisappear {
            guard !demo else { return }
            Task.detached { _ = RustCore.trouterStop() }
        }
    }

    /// Trouter poll loop (skipped in demo): typed events for the open
    /// chat ingest as messages/edits; resync re-fetches the list.
    private func runLive() async {
        guard !demo else { return }
        let rc = await Task.detached { RustCore.trouterStart() }.value
        guard rc == 0 || rc == -1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            do {
                let poll = try await Task.detached { try RustCore.trouterPollTyped() }.value
                for m in poll.messages where m.chatID == conversation.chatID {
                    if m.isEdit, let eid = m.editedID {
                        conversation.ingestEdited(id: eid, content: m.text)
                    } else {
                        conversation.ingest(ChatMessage(
                            id: m.msgId, sender: m.sender,
                            timestamp: m.time, content: m.text))
                    }
                }
                if poll.resync { await chats.load() }
            } catch {
                continue
            }
        }
    }
}
