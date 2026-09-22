// TeamsBrowser.swift — SwiftUI browser: teams + channels, opens conversations.
import OstMacCore
import SwiftUI

/// Teams/channels browser. Tapping a channel calls `onOpen` with the
/// channel id + display name; the host opens it as a conversation through
/// the same path as chats (channel ids are conversation ids).
public struct TeamsBrowser: View {
    @ObservedObject private var model: TeamsViewModel
    private let openChatID: String?
    private let onOpen: (String, String) -> Void
    @State private var searchText = ""

    public init(model: TeamsViewModel, openChatID: String? = nil, onOpen: @escaping (String, String) -> Void) {
        self.model = model
        self.openChatID = openChatID
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading teams…").font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                VStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No teams").font(.headline)
                    Text("Teams you join will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Couldn't load teams").font(.headline)
                    Text(message).font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") { model.refresh() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .loaded:
                let visible = TeamsViewModel.filtered(model.teams, query: searchText)
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No matches").font(.headline)
                        Text("No teams or channels match \"\(searchText)\".")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(visible) { team in
                            Section {
                                if team.channels.isEmpty {
                                    Text("No channels")
                                        .font(.callout).foregroundStyle(.secondary)
                                } else {
                                    ForEach(team.channels) { channel in
                                        ChannelRow(
                                            channel: channel,
                                            teamName: team.name,
                                            isOpen: channel.id == openChatID,
                                            onOpen: onOpen)
                                    }
                                }
                            } header: {
                                Label(team.name, systemImage: "person.3.fill")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .navigationTitle("Teams")
        .searchable(text: $searchText, prompt: "Filter teams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh teams list")
                .disabled(model.state == .loading)
            }
        }
    }
}

struct ChannelRow: View {
    let channel: TeamChannel
    let teamName: String
    let isOpen: Bool
    let onOpen: (String, String) -> Void

    var body: some View {
        Button {
            onOpen(channel.id, "\(teamName) > #\(channel.name)")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                Text(channel.name).lineLimit(1)
                Spacer()
                if isOpen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
