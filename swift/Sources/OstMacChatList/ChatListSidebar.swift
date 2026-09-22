// ChatListSidebar.swift — SwiftUI sidebar: chats + loading/empty/error states.
import OstMacCore
import SwiftUI

/// Sidebar list of chats. Selection writes through to `model.selectedChatID`
/// for the conversation lane to consume.
public struct ChatListSidebar: View {
    @ObservedObject private var model: ChatListViewModel

    public init(model: ChatListViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading chats…").font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No chats").font(.headline)
                    Text("Your Teams conversations will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Couldn't load chats").font(.headline)
                    Text(message).font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") { model.refresh() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .loaded:
                List(selection: $model.selectedChatID) {
                    ForEach(model.chats) { chat in
                        ChatRow(chat: chat).tag(chat.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh chat list")
                .disabled(model.state == .loading)
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: chat.is_group ? "person.3.fill" : "person.circle.fill")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ChatListFormat.previewTime(chat.last_message_time))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var previewText: String {
        let line = ChatListFormat.previewLine(
            sender: chat.last_message_sender,
            preview: chat.last_message_preview)
        return line.isEmpty ? "No messages" : line
    }
}
