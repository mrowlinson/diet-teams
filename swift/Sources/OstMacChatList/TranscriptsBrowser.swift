// TranscriptsBrowser.swift — SwiftUI browser: searchable transcripts + turns.
import DietDesign
import OstMacCore
import SwiftUI

/// Transcripts browser. Search field on top, transcript rows below;
/// tapping a row selects it and the turns card pins beneath the list
/// (speaker turns, Open/Save). Mirrors RecordingsBrowser states
/// (DietDesign rows, `DietSeamH`).
public struct TranscriptsBrowser: View {
    @ObservedObject private var model: TranscriptsViewModel
    @ObservedObject private var actions: ActionItemsStore
    @State private var query = ""
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: TranscriptsViewModel) {
        self.model = model
        self._actions = ObservedObject(wrappedValue: model.actionItems)
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading transcripts…")
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
                        message: "No transcripts match “\(model.lastQuery)”.",
                        actionLabel: "Clear",
                        action: {
                            query = ""
                            model.clearSearch()
                        })
                }
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "doc.text",
                    title: "No transcripts",
                    message: "Meeting transcripts will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load transcripts",
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
                    model.select(item)
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
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, DietSpace.xxs)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            if model.selectedID != nil {
                turnsCard
            }
        }
    }

    private var searchField: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                DietSearchField("Search transcripts", text: $query)
                    .onSubmit { Task { await model.search(query: query) } }
                    .onChange(of: query) { _, new in
                        if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            model.clearSearch()
                        }
                    }
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
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
    private var turnsCard: some View {
        VStack(spacing: 0) {
            DietSeamH()
            VStack(alignment: .leading, spacing: DietSpace.xs) {
                HStack(spacing: DietSpace.xs) {
                    Text(model.contentTitle ?? model.selected?.name ?? "Transcript")
                        .font(DietType.body)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.closeTranscript()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .buttonStyle(.plain)
                    .help("Close transcript")
                }
                switch model.content {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: DietSpace.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(DietType.callout)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                case .loaded:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DietSpace.xs) {
                            ForEach(model.cues) { cue in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: DietSpace.xs) {
                                        if let speaker = cue.speaker {
                                            Text(speaker)
                                                .font(DietType.caption1)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(DietColor.textPrimaryColor)
                                        }
                                        Text(cue.startLabel)
                                            .font(DietType.caption1)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text(cue.text)
                                        .font(DietType.callout)
                                        .foregroundStyle(DietColor.textPrimaryColor)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    actionsRow
                    actionItemsSection
                case .failed(let message):
                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                        Text(message)
                            .font(DietType.callout)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            if let item = model.selected { model.select(item) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(DietSpace.sm)
        }
    }

    /// Extraction results inline in the turns card (idle shows
    /// nothing; the list above never flashes or re-lays-out).
    @ViewBuilder
    private var actionItemsSection: some View {
        switch actions.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: DietSpace.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Extracting…")
                    .font(DietType.callout)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DietSpace.xs)
        case let .loaded(items):
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                DietSeamH()
                Text("Action items")
                    .font(DietType.caption1)
                    .fontWeight(.semibold)
                    .foregroundStyle(DietColor.textSecondaryColor)
                ActionItemsBulletsView(items: items)
                    .frame(maxHeight: 160)
            }
            .padding(.top, DietSpace.xs)
        case let .empty(copy):
            Text(copy)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DietSpace.xs)
        case let .failed(detail):
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                Text(detail)
                    .font(DietType.callout)
                    .foregroundStyle(.red)
                if actions.lastError?.isOnDevice == true {
                    CatchUpOnDeviceGuidance()
                }
                Button("Retry") {
                    Task { await model.extractActionItems() }
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DietSpace.xs)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: DietSpace.sm) {
            if let item = model.selected {
                Button("Open") { model.open(item) }
                    .buttonStyle(.link)
                    .disabled(item.web_url == nil)
                Button("Save") { model.save(item) }
                    .buttonStyle(.link)
                    .disabled(item.drive_id == nil)
                Button("Action items") {
                    Task { await model.extractActionItems() }
                }
                .buttonStyle(.link)
                .disabled(model.cues.isEmpty)
                .help("Extract action items on this Mac (Apple Intelligence)")
            }
            if model.siblingRecording != nil {
                Label("Matching recording", systemImage: "film")
                    .font(DietType.caption1)
                    .foregroundStyle(Color.accentColor)
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
            } else {
                // Drive-backed limits (B2 verdict): organizer-only for
                // 1:1/private meetings; stem linkage, no id join; no
                // live-event transcripts.
                Text("Organizer's copy · matched by filename")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            }
        }
    }
}
