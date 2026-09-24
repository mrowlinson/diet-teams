// MeetingChat.swift — om-meet-chat lane: meeting conversation.
//
// A meeting has two live surfaces, both fed by the realtime feed and
// neither ever refreshing the chat list:
// - MeetingRosterStore: the participant roster (speaking/mute states
//   upserted in place by id from core `roster[]` events).
// - MeetingChatStore: the meeting chat panel during the call plus the
//   persisted thread after it (meeting-thread messages adopt the panel
//   on first sight; every mutation persists to disk, so the thread
//   survives app restarts and the meeting ending).
//
//   feed.onRoster { [weak self] ev in
//       Task { @MainActor [weak self] in self?.meeting.ingest(ev) } }
//
// No polling (rides the existing feed), no chat-list refresh (roster
// and meeting chat never touch the list — the panel is the only
// surface, counters in Diagnostics).
import DietDesign
import Foundation
import SwiftUI

// MARK: - Roster events + rows

/// One participant snapshot from the live feed (core `roster[]`).
/// `speaking`/`muted`/`present` are nil when the frame said nothing
/// about that axis (the store keeps the last-known value). `name` is
/// "" on speaker-only markers (the store keeps the roster name).
public struct MeetingRosterEvent: Decodable, Sendable, Equatable {
    public let meetingID: String
    public let id: String
    public let name: String
    public let speaking: Bool?
    public let muted: Bool?
    public let present: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, speaking, muted, present
        case meetingID = "meeting_id"
    }

    /// Host-side construction (tests, mock feeds).
    public init(
        meetingID: String = "", id: String, name: String,
        speaking: Bool? = nil, muted: Bool? = nil, present: Bool? = nil
    ) {
        self.meetingID = meetingID
        self.id = id
        self.name = name
        self.speaking = speaking
        self.muted = muted
        self.present = present
    }

    /// True when this event belongs to the given meeting. Empty never
    /// matches (unattributed frames apply to the open roster instead).
    public func isFor(meetingID id: String?) -> Bool {
        guard !meetingID.isEmpty else { return false }
        return id.map { $0 == meetingID } ?? false
    }
}

/// One roster row: identity + live speaking/mute state.
public struct MeetingParticipant: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var speaking: Bool
    public var muted: Bool
    public var present: Bool

    public init(id: String, name: String, speaking: Bool = false, muted: Bool = false, present: Bool = true) {
        self.id = id
        self.name = name
        self.speaking = speaking
        self.muted = muted
        self.present = present
    }
}

// MARK: - Roster store

/// Single-meeting roster, updated in place by participant id.
/// Main-actor (SwiftUI-owned).
@MainActor
public final class MeetingRosterStore: ObservableObject {
    /// Rows in join order; updates never reorder (in-place upsert).
    @Published public private(set) var participants: [MeetingParticipant] = []
    /// Attributed meeting id, or nil while only unattributed frames
    /// have landed.
    @Published public private(set) var meetingID: String?

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits; all members stay main-actor-isolated.
    public nonisolated init() {}

    /// Upsert one snapshot by id (new ids append, known ids merge in
    /// place — name only when non-empty, axes only when non-nil).
    /// Empty ids are ignored (nothing to attribute). `present == false`
    /// removes the row (unknown leaves are a no-op). `speaking == true`
    /// solos: every other row clears (dominant-speaker semantics).
    /// A non-empty meeting id for another meeting resets the roster
    /// first (single-meeting model, like the single-call slot).
    public func ingest(_ event: MeetingRosterEvent) {
        guard !event.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !event.meetingID.isEmpty, let cur = meetingID, cur != event.meetingID {
            participants = []
        }
        if !event.meetingID.isEmpty { meetingID = event.meetingID }
        if event.present == false {
            participants.removeAll { $0.id == event.id }
            return
        }
        if participants.contains(where: { $0.id == event.id }) {
            for i in participants.indices where participants[i].id == event.id {
                if !event.name.isEmpty { participants[i].name = event.name }
                if let m = event.muted { participants[i].muted = m }
                participants[i].present = true
            }
            if let s = event.speaking { applySpeaking(id: event.id, speaking: s) }
        } else {
            participants.append(MeetingParticipant(
                id: event.id,
                name: event.name.isEmpty ? "?" : event.name,
                speaking: false,
                muted: event.muted ?? false,
                present: true))
            if let s = event.speaking { applySpeaking(id: event.id, speaking: s) }
        }
    }

    public func ingest(_ events: [MeetingRosterEvent]) {
        for e in events { ingest(e) }
    }

    /// Speaking rows (usually one — dominant speaker).
    public var speaking: [MeetingParticipant] {
        participants.filter(\.speaking)
    }

    /// Live row count (Diagnostics counter source).
    public var activeCount: Int { participants.count }

    /// Speaking rows (Diagnostics counter source).
    public var speakingCount: Int { speaking.count }

    /// Muted rows (Diagnostics counter source).
    public var mutedCount: Int { participants.filter(\.muted).count }

    /// The meeting ended: every row stops speaking (last-known roster
    /// stays visible; the persisted thread keeps the history).
    public func noteMeetingEnded() {
        for i in participants.indices { participants[i].speaking = false }
    }

    /// Adopt rows without the feed (tests, previews, demo).
    public func adopt(_ list: [MeetingParticipant], meetingID: String? = nil) {
        participants = list
        self.meetingID = meetingID
    }

    /// Seed offline demo state (shot hook: --show-meeting).
    public func seedDemo() {
        adopt(MeetingDemo.participants, meetingID: MeetingDemo.threadID)
    }

    /// Drop everything after sign-out (fail closed).
    public func clear() {
        participants = []
        meetingID = nil
    }

    /// Speaking solo: true lights this row and clears the rest; false
    /// clears this row only.
    private func applySpeaking(id: String, speaking: Bool) {
        for i in participants.indices {
            if participants[i].id == id {
                participants[i].speaking = speaking
            } else if speaking {
                participants[i].speaking = false
            }
        }
    }
}

// MARK: - Meeting chat store

/// Meeting-thread chat: live panel during the call, persisted thread
/// after. Meeting-thread realtime events adopt the panel on first
/// sight; every mutation persists to disk (Application Support), so
/// the thread survives restarts and the meeting ending. History merges
/// over the persisted snapshot on open (live-only ids survive).
/// Main-actor (SwiftUI-owned).
@MainActor
public final class MeetingChatStore: ObservableObject {
    public typealias LoadPersisted = @Sendable (String) -> [ChatMessage]
    public typealias SavePersisted = @Sendable (String, [ChatMessage]) -> Void
    public typealias DeletePersisted = @Sendable (String) -> Void

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var meetingActive = false
    @Published public private(set) var didLoad = false
    public private(set) var threadID: String?
    public private(set) var threadName: String?
    public private(set) var isDemo = false
    /// Own sender name (whoami display_name); nil until resolved or in demo.
    public private(set) var ownDisplayName: String?
    private var openGeneration = 0

    private let loadPersisted: LoadPersisted
    private let savePersisted: SavePersisted
    private let deletePersisted: DeletePersisted

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits; all members stay main-actor-isolated. Tests inject
    /// in-memory persistence (same seam as ChatListViewModel.Fetcher).
    public nonisolated init(
        load: @escaping LoadPersisted = MeetingChatStore.fileLoad,
        save: @escaping SavePersisted = MeetingChatStore.fileSave,
        delete: @escaping DeletePersisted = MeetingChatStore.fileDelete
    ) {
        self.loadPersisted = load
        self.savePersisted = save
        self.deletePersisted = delete
    }

    /// Header title: the thread name, else the generic label — never
    /// the raw thread id (om-chatnames).
    public var headerTitle: String {
        if let n = threadName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return "Meeting chat"
    }

    /// Open a meeting thread: the persisted snapshot shows instantly,
    /// then history merges over it. Stale completions are dropped.
    public func open(threadID: String, chatName: String? = nil, limit: Int32 = 50) {
        self.threadID = threadID
        if let n = chatName { self.threadName = n }
        messages = stamped(loadPersisted(threadID))
        meetingActive = true
        loading = true
        error = nil
        didLoad = false
        openGeneration += 1
        let gen = openGeneration
        Task {
            let own: String? = try? await Task.detached {
                try RustCore.whoami().display_name
            }.value
            guard gen == self.openGeneration else { return }
            if let own { self.ownDisplayName = own }
            do {
                let resp = try await Task.detached {
                    try RustCore.messages(chatID: threadID, limit: limit)
                }.value
                guard gen == self.openGeneration else { return }
                self.messages = Self.merge(
                    history: self.stamped(resp.messages), keeping: self.messages)
                self.didLoad = true
                self.loading = false
                self.persist()
            } catch {
                guard gen == self.openGeneration else { return }
                self.loading = false
                self.didLoad = true
                // The persisted snapshot stays visible; the error
                // surfaces with retry (never a blank panel).
                self.error = String(describing: error)
            }
        }
    }

    /// Re-run `open` for the current thread (Try Again). No-op without
    /// a thread, or in demo mode (demo never hits core).
    public func retryOpen(limit: Int32 = 50) {
        guard !isDemo, let id = threadID else { return }
        open(threadID: id, limit: limit)
    }

    /// Live routing (the AppState feed hook): meeting-thread events
    /// adopt the panel on first sight (persisted snapshot + history
    /// load, like open) and upsert every match; other threads upsert
    /// only when already open. Never touches the chat list.
    public func ingestIfMeeting(realtime message: RealtimeMessage) {
        if let open = threadID {
            guard message.isFor(chatID: open) else { return }
            ingestLive(message)
            return
        }
        guard MeetingSignal.isMeetingThread(message.chatID) else { return }
        open(threadID: message.chatID)
        ingestLive(message)
    }

    /// Demo mode: show canned messages (offline, no core).
    public func showDemo(threadID: String, chatName: String, messages: [ChatMessage]) {
        self.threadID = threadID
        self.threadName = chatName
        self.messages = messages
        isDemo = true
        meetingActive = true
        loading = false
        error = nil
        didLoad = true
    }

    /// Adopt an identity without core (tests, sign-in completion).
    public func adoptIdentity(displayName: String) {
        ownDisplayName = displayName
        messages = stamped(messages)
    }

    /// The meeting ended: the thread stays readable (and persisted) —
    /// only the live marker flips.
    public func endMeeting() {
        meetingActive = false
        persist()
    }

    /// Post via core; appends an optimistic own-bubble immediately and
    /// persists. Demo mode appends locally without touching core.
    public func send(text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if isDemo {
            messages.append(ChatMessage(
                id: "demo-local-\(messages.count + 1)",
                sender: "Me", timestamp: ConversationStore.nowISO(),
                content: body, isOwn: true))
            persist()
            return
        }
        guard let id = threadID else { return }
        messages.append(ChatMessage(
            id: "pending-\(UUID().uuidString)",
            sender: "Me", timestamp: ConversationStore.nowISO(),
            content: body, isOwn: true))
        persist()
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.send(chatID: id, text: body)
                }.value
            } catch {
                self.error = "send failed: \(error)"
            }
        }
    }

    /// Drop memory after sign-out and delete the persisted snapshot
    /// (fail closed; history re-fetches on the next sign-in).
    public func clear() {
        if let id = threadID { deletePersisted(id) }
        threadID = nil
        threadName = nil
        messages = []
        error = nil
        didLoad = false
        meetingActive = false
        openGeneration += 1
    }

    /// Pure merge: history order wins, live-only ids append (the live
    /// bubble that landed before history never drops).
    public static func merge(history: [ChatMessage], keeping live: [ChatMessage]) -> [ChatMessage] {
        let known = Set(history.map(\.id))
        return history + live.filter { !known.contains($0.id) }
    }

    private func ingestLive(_ message: RealtimeMessage) {
        let targetID: String
        if message.isEdit, let edited = message.editedID {
            targetID = edited
        } else {
            targetID = message.msgId
        }
        if message.text.isEmpty, let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
            persist()
            return
        }
        var m = message.asChatMessage
        m.isOwn = ownDisplayName.map { m.sender == $0 } ?? false
        messages = ConversationStore.upsert(m, into: messages)
        if let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
        }
        persist()
    }

    /// Replace one bubble's counts (realtime patch, server truth).
    /// Unknown ids are a no-op — counts never conjure a bubble.
    private func applyReactions(id: String, reactions: [ReactionCount]) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].reactions = reactions
    }

    private func stamped(_ list: [ChatMessage]) -> [ChatMessage] {
        ConversationStore.stampOwnership(list, ownName: ownDisplayName)
    }

    private func persist() {
        guard let id = threadID else { return }
        savePersisted(id, messages)
    }

    // MARK: - File persistence (default seam)

    public static func meetingsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diet Teams/meetings", isDirectory: true)
    }

    /// Thread id → safe filename (alphanumerics kept, capped length).
    public static func fileName(for threadID: String) -> String {
        let safe = threadID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        let trimmed = String(safe.prefix(120))
        return (trimmed.isEmpty ? "meeting" : trimmed) + ".json"
    }

    public static func fileLoad(threadID: String) -> [ChatMessage] {
        guard let dir = meetingsDirectory() else { return [] }
        let url = dir.appendingPathComponent(fileName(for: threadID))
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    public static func fileSave(threadID: String, messages: [ChatMessage]) {
        guard let dir = meetingsDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: dir.appendingPathComponent(fileName(for: threadID)), options: .atomic)
    }

    public static func fileDelete(threadID: String) {
        guard let dir = meetingsDirectory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName(for: threadID)))
    }
}

// MARK: - Demo data (shot hook: --show-meeting)

public enum MeetingDemo {
    public static let threadID = "19:meeting_demo@thread.v2"
    public static let threadName = "Demo — Design Sync (meeting)"

    public static let participants = [
        MeetingParticipant(id: "8:orgid:megan", name: "Megan Harper", speaking: true),
        MeetingParticipant(id: "8:orgid:tom", name: "Tom Becker", muted: true),
        MeetingParticipant(id: "8:orgid:me", name: "Me"),
    ]

    public static let messages = [
        ChatMessage(
            id: "meet-1", sender: "Megan Harper",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Morning! Design sync in 10. Dropping the agenda here."),
        ChatMessage(
            id: "meet-2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:04:47Z",
            content: "Mocks are up — link in the Shared tab after the call."),
        ChatMessage(
            id: "meet-3", sender: "Me",
            timestamp: "2026-09-22T09:07:30Z",
            content: "On mute, following along.", isOwn: true),
    ]
}

// MARK: - Views (native macOS, no counters — Diagnostics only)

// Accessibility + icon contract shared by the row and tests.
public enum MeetingRosterFormat {
    public static func micIcon(muted: Bool) -> String {
        muted ? "mic.slash.fill" : "mic.fill"
    }

    public static func accessibilityLabel(for p: MeetingParticipant) -> String {
        var parts = [p.name]
        parts.append(p.muted ? "muted" : "unmuted")
        if p.speaking { parts.append("speaking") }
        return parts.joined(separator: ", ")
    }
}

/// One roster row: mic state + name + speaking marker.
public struct MeetingRosterRow: View {
    public let participant: MeetingParticipant

    public init(participant: MeetingParticipant) {
        self.participant = participant
    }

    public var body: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: MeetingRosterFormat.micIcon(muted: participant.muted))
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(participant.muted
                    ? Color(nsColor: DietColor.danger)
                    : DietColor.textSecondaryColor)
                .frame(width: 20)
            Text(participant.name)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
            Spacer(minLength: DietSpace.sm)
            if participant.speaking {
                Image(systemName: "waveform")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(Color(nsColor: DietColor.success))
            }
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.xs)
        .background(participant.speaking
            ? Color(nsColor: DietColor.success).opacity(0.12)
            : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
        .accessibilityLabel(MeetingRosterFormat.accessibilityLabel(for: participant))
    }
}

/// The roster list: rows update in place as events land.
public struct MeetingRosterView: View {
    @ObservedObject public var store: MeetingRosterStore

    public init(store: MeetingRosterStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Participants")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.xs)
            DietSeamH()
            if store.participants.isEmpty {
                DietEmptyState(
                    systemImage: "person.3",
                    title: "No participants yet",
                    message: "The roster fills in as the meeting feed reports who is here.")
                    .padding(DietSpace.md)
            } else {
                ScrollView {
                    LazyVStack(spacing: DietSpace.xxs) {
                        ForEach(store.participants) { p in
                            MeetingRosterRow(participant: p)
                        }
                    }
                    .padding(DietSpace.xs)
                }
            }
        }
    }
}

/// One meeting-chat bubble: sender + time caption over the bubble.
struct MeetingBubbleRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.isOwn ? .trailing : .leading, spacing: 2) {
            Text("\(message.sender) · \(message.displayTime)")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            DietBubble(
                message.content,
                direction: message.isOwn ? .outgoing : .incoming)
        }
    }
}

/// The meeting chat panel: live bubbles during the call, persisted
/// thread after. Native scroll + send box (no counts).
public struct MeetingChatPanel: View {
    @ObservedObject public var chat: MeetingChatStore
    @State private var draft = ""
    @FocusState private var boxFocused: Bool
    @StateObject private var scroll = ChatScrollModel()
    /// Reduce Motion (om-a1-motion): scrollToBottom lands instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(chat: MeetingChatStore) {
        self.chat = chat
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietHeaderBar {
                HStack(spacing: DietSpace.sm) {
                    Text(chat.headerTitle)
                        .font(DietType.headline)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Text(chat.meetingActive ? "Live" : "Ended")
                        .font(DietType.caption2).bold()
                        .padding(.horizontal, DietSpace.xs)
                        .padding(.vertical, DietSpace.xxs)
                        .background(
                            chat.meetingActive
                                ? Color(nsColor: DietColor.success).opacity(0.85)
                                : DietColor.wellColor,
                            in: Capsule())
                        .foregroundStyle(chat.meetingActive
                            ? .white : DietColor.textSecondaryColor)
                        .accessibilityLabel(chat.meetingActive ? "Meeting live" : "Meeting ended")
                    Spacer(minLength: DietSpace.sm)
                    if chat.loading { ProgressView().controlSize(.small) }
                }
            }
            if let err = chat.error {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.md)
                    .padding(.vertical, DietSpace.sm)
            }
            if chat.messages.isEmpty, !chat.loading {
                DietEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: chat.threadID == nil ? "No meeting yet" : "No messages yet",
                    message: chat.threadID == nil
                        ? "Join a meeting to see its chat here."
                        : "Messages sent to the meeting thread land here.")
                    .padding(DietSpace.md)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DietSpace.sm) {
                                ForEach(chat.messages) { m in
                                    MeetingBubbleRow(message: m)
                                        .id(m.id)
                                }
                                // Bottom sentinel (FIX-scroll port): the TRUE
                                // content end, laid out LAST with the trailing
                                // inset as part of it — scrollToBottom lands
                                // on the exact content end with zero gap.
                                // Dwell hugs the tail (kills the pill);
                                // leaving cancels settle (no yank races).
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, DietSpace.md)
                                    .id(ScrollPolicy.bottomSentinelID)
                                    .onAppear {
                                        scroll.noteBottomDwell(tailID: chat.messages.last?.id)
                                    }
                                    .onDisappear {
                                        scroll.noteLeftBottom()
                                    }
                            }
                            .padding([.top, .leading, .trailing], DietSpace.md)
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: chat.messages.count) { handleMessagesChanged(proxy) }
                        .onChange(of: chat.loading) { handleLoadingChanged(proxy) }
                        .onAppear {
                            scroll.lastSeenID = chat.messages.last?.id
                            scroll.lastReadID = chat.messages.last?.id
                            settleToBottom(proxy)
                        }
                        if let action = bottomAction {
                            switch action {
                            case .pill(let title):
                                Button { jumpTap(proxy) } label: {
                                    HStack(spacing: DietSpace.xs) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text(title)
                                            .font(DietType.caption1).bold()
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, DietSpace.sm + DietSpace.xs)
                                    .padding(.vertical, DietSpace.xs)
                                    .background(Color.accentColor, in: Capsule())
                                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                }
                                .buttonStyle(.plain)
                                .help("Jump to latest messages")
                                .padding(.bottom, DietSpace.sm)
                            case .jump:
                                Button { jumpTap(proxy) } label: {
                                    HStack(spacing: DietSpace.xs) {
                                        Image(systemName: "arrow.down.circle")
                                        Text("Jump to latest")
                                            .font(DietType.caption1).bold()
                                    }
                                    .foregroundStyle(DietColor.textPrimaryColor)
                                    .padding(.horizontal, DietSpace.sm + DietSpace.xs)
                                    .padding(.vertical, DietSpace.xs)
                                    .background(DietColor.wellColor, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(DietColor.dividerColor, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                }
                                .buttonStyle(.plain)
                                .help("Jump to latest messages")
                                .padding(.bottom, DietSpace.sm)
                            }
                        }
                    }
                }
            }
            DietSeamH()
            HStack(spacing: DietSpace.sm) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($boxFocused)
                    .padding(.horizontal, DietSpace.sm)
                    .frame(minHeight: DietSize.controlHeight)
                    .background(DietColor.wellColor)
                    .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: DietRadius.control)
                            .stroke(
                                boxFocused ? Color.accentColor : DietColor.dividerColor,
                                lineWidth: boxFocused ? 2 : 1)
                    )
                    .onSubmit { submit() }
                    .disabled(chat.threadID == nil)
                Button("Send", systemImage: "paperplane.fill") { submit() }
                    .buttonStyle(.dietPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(chat.threadID == nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DietSpace.md)
        }
        .background(DietColor.windowColor)
    }

    /// Exact-bottom landing target (FIX-scroll port): always the
    /// bottom sentinel (true content end), never the tail bubble.
    /// Targeting the last bubble parks the 16pt trailing inset below
    /// the fold. Nil tail (empty thread) → nil. Internal so tests pin
    /// it; every land below funnels through here.
    static func landingTarget(tailID: String?) -> String? {
        ScrollPolicy.bottomTargetID(tailID: tailID)
    }

    private var unseen: Int {
        scroll.unseenCount(messages: chat.messages)
    }

    private var bottomAction: BottomAction? {
        ScrollPolicy.bottomAction(unseen: unseen, nearBottom: scroll.nearBottom)
    }

    /// Tail advance → follow or pill; anything else (edit in place,
    /// same-tail refresh) holds position. Meeting history merges on
    /// open land via handleLoadingChanged instead.
    private func handleMessagesChanged(_ proxy: ScrollViewProxy) {
        switch scroll.consumeTail(
            currentTailID: chat.messages.last?.id,
            isOwnTail: chat.messages.last?.isOwn ?? false)
        {
        case .follow:
            scrollToBottom(proxy)
        case .pill:
            break // the pill absorbs it (unseen derives from lastReadID)
        case .none:
            break
        }
    }

    /// Open history merge finished: land on latest (the merge may have
    /// prepended over the persisted snapshot mid-scroll).
    private func handleLoadingChanged(_ proxy: ScrollViewProxy) {
        if !chat.loading {
            scroll.lastSeenID = chat.messages.last?.id
            scroll.jumpToLatest(tailID: chat.messages.last?.id)
            settleToBottom(proxy)
        }
    }

    private func jumpTap(_ proxy: ScrollViewProxy) {
        scroll.jumpToLatest(tailID: chat.messages.last?.id)
        scrollToBottom(proxy)
    }

    /// Exact-bottom landing: targets the bottom sentinel (true content
    /// end), never the tail bubble. Empty thread → no-op.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = Self.landingTarget(tailID: chat.messages.last?.id) else { return }
        let animate = DietMotion.scrollAnimated(requested: animated, reduceMotion: reduceMotion)
        DispatchQueue.main.async {
            if animate {
                withAnimation { proxy.scrollTo(target, anchor: .bottom) }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    /// Initial land + timed re-asserts while the reader stays near the
    /// bottom. Rows settle as content resolves, so one scroll can land
    /// short; each pass re-reads live `nearBottom`, and leaving the
    /// bottom cancels the task outright.
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        scroll.cancelSettle()
        scroll.settleTask = Task { @MainActor in
            var waited: TimeInterval = 0
            for step in ScrollPolicy.settleDelays {
                let nanos = UInt64(max(0, step - waited) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                waited = step
                guard !Task.isCancelled else { return }
                if scroll.nearBottom { scrollToBottom(proxy, animated: false) }
            }
        }
    }

    private func submit() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        chat.send(text: body)
    }
}

/// Roster + chat side by side: the Meeting window content.
public struct MeetingPanel: View {
    @ObservedObject public var roster: MeetingRosterStore
    @ObservedObject public var chat: MeetingChatStore

    public init(roster: MeetingRosterStore, chat: MeetingChatStore) {
        self.roster = roster
        self.chat = chat
    }

    public var body: some View {
        HSplitView {
            MeetingRosterView(store: roster)
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
            MeetingChatPanel(chat: chat)
                .frame(minWidth: 320)
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}
