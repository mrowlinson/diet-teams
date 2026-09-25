// RecordingsBrowser.swift — SwiftUI browser: searchable recordings + player.
import AVKit
import DietDesign
import OstMacCore
import SwiftUI

/// Recordings browser. Search field on top, recording rows below;
/// tapping a row selects it and the player card pins beneath the list
/// (16:9 video, transport + Open/Save). Mirrors RemindersBrowser
/// states (DietDesign rows, `DietSeamH`).
public struct RecordingsBrowser: View {
    @ObservedObject private var model: RecordingsViewModel
    @State private var query = ""
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: RecordingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading recordings…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty where model.isSearchResults:
                VStack(spacing: 0) {
                    searchField
                    DietEmptyState(
                        systemImage: "magnifyingglass",
                        title: "No matches",
                        message: "No recordings match “\(model.lastQuery)”.",
                        actionLabel: "Clear",
                        action: {
                            query = ""
                            model.clearSearch()
                        })
                }
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "film",
                    title: "No recordings",
                    message: "Meeting recordings will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load recordings",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedBody
                    .transition(.opacity)
            }
        }
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: model.state)
    }

    private var loadedBody: some View {
        VStack(spacing: 0) {
            searchField
            List(model.items) { item in
                Button {
                    if model.selectedID == item.id {
                        model.play(item)
                    } else {
                        model.select(item)
                    }
                } label: {
                    HStack(spacing: DietSpace.sm) {
                        Image(systemName: item.iconName)
                            .font(.system(size: DietSize.iconMD))
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .frame(width: DietSize.iconLG)
                        VStack(alignment: .leading, spacing: DietSpace.xxs) {
                            Text(item.name)
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .lineLimit(1)
                            HStack(spacing: DietSpace.xs) {
                                if let source = item.source {
                                    Text(source)
                                        .font(DietType.caption1)
                                        .foregroundStyle(Color.accentColor)
                                }
                                if !item.detailLine.isEmpty {
                                    Text(item.detailLine)
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor.textSecondaryColor)
                                }
                            }
                            .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if model.selectedID == item.id {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, DietSpace.xxs)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            if model.selectedID != nil {
                playerCard
            }
        }
    }

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DietColor.textSecondaryColor)
                TextField("Search recordings", text: $query, onCommit: {
                    Task { await model.search(query: query) }
                })
                .textFieldStyle(.plain)
                .font(DietType.body)
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            if let err = model.searchError {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.bottom, DietSpace.xxs)
            }
            DietSeamH()
        }
    }

    @ViewBuilder
    private var playerCard: some View {
        VStack(spacing: 0) {
            DietSeamH()
            VStack(alignment: .leading, spacing: DietSpace.xs) {
                HStack(spacing: DietSpace.xs) {
                    Text(model.playTitle ?? model.selected?.name ?? "Recording")
                        .font(DietType.body)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.closePlayer()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .buttonStyle(.plain)
                    .help("Close player")
                }
                switch model.playback {
                case .idle:
                    Button {
                        if let item = model.selected { model.play(item) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .loading:
                    HStack(spacing: DietSpace.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(DietType.callout)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                case .playing, .paused:
                    if let player = model.player {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    transportRow
                case .failed(let message):
                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                        Text(message)
                            .font(DietType.callout)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            if let item = model.selected { model.play(item) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(DietSpace.sm)
        }
    }

    private var transportRow: some View {
        HStack(spacing: DietSpace.sm) {
            Button {
                model.toggle()
            } label: {
                Image(systemName: model.playback == .playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(model.playback == .playing ? "Pause" : "Play")
            if let item = model.selected {
                Button("Open") { model.open(item) }
                    .buttonStyle(.link)
                    .disabled(item.web_url == nil)
                Button("Save") { model.save(item) }
                    .buttonStyle(.link)
                    .disabled(item.drive_id == nil)
            }
            Spacer(minLength: 0)
            if let path = model.savedPath {
                Text("Saved \(URL(fileURLWithPath: path).lastPathComponent)")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            } else if let err = model.actionError {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let dur = model.selected?.durationLabel {
                Text(dur)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
        }
    }
}
