// Notifications.swift — om-notif: macOS user notifications for realtime chat.
//
// Pipeline: AppState.handleRealtime runs every live event through the
// rules engine (ChatFilter) and posts .notify decisions via Notifier;
// this type owns the banner toggle + authorization + the single shared
// response delegate. Click returns to the chat via NotificationCenter
// (.omNotifOpenChat); the message category carries an inline reply
// action (.omNotifReply → core send). The handle() gate below (edits,
// own messages, open chat) is the injectable-backend path tests use;
// live posts go through the NcDelivery banner + Notifier instead.
// Routing, thread grouping, and lock-screen redaction are shared with
// the rules path through NcDelivery (same route map, both userInfo keys).
//
// The backend is injectable: SystemNotificationCenter (real UNUser
// center) in the app, FakeNotificationCenter (in-memory log) in tests.
import Foundation
import UserNotifications

public extension Notification.Name {
    /// userInfo: ["chatID": String] — open (jump to) the chat.
    static let omNotifOpenChat = Notification.Name("om-notif-open-chat")
    /// userInfo: ["chatID": String, "text": String] — send a reply.
    static let omNotifReply = Notification.Name("om-notif-reply")
}

/// One posted chat notification (backend record + delivered log entry).
/// `threadIdentifier` groups banners per thread (defaults to the chatID).
/// Elevated mentions carry the OM_MENTION style (distinct sound +
/// subtitle); plain messages the default style.
public struct PostedNotification: Sendable, Equatable {
    public let id: String // msgId (also the UN request identifier)
    public let chatID: String
    public let title: String
    public let body: String
    /// `threadIdentifier` groups banners per thread (defaults to the chatID).
    public let threadIdentifier: String
    /// Play the banner sound. False = silent post (Settings → Sound).
    public let sound: Bool
    public let isMention: Bool
    /// Banner subtitle for elevated mentions ("Mentioned you" /
    /// "Channel mention"); nil for plain messages.
    public let subtitle: String?

    public init(id: String, chatID: String, title: String, body: String, threadIdentifier: String? = nil, sound: Bool = true, isMention: Bool = false, subtitle: String? = nil) {
        self.id = id
        self.chatID = chatID
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier ?? chatID
        self.sound = sound
        self.isMention = isMention
        self.subtitle = subtitle
    }
}

/// Post/deliver surface: the real center or an in-memory fake.
public protocol NotificationPosting: Sendable {
    func requestAuthorization() async throws -> Bool
    func post(_ note: PostedNotification) async
    func delivered() async -> [PostedNotification]
}

/// Real backend over UNUserNotificationCenter. Posts carry chatID/msgID
/// in userInfo; the OM_MESSAGE category adds the inline Reply action.
public final class SystemNotificationCenter: NotificationPosting, @unchecked Sendable {
    public static let categoryID = "OM_MESSAGE"
    public static let replyActionID = "OM_REPLY"
    public static let chatIDKey = "chatID"
    public static let msgIDKey = "msgID"

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ note: PostedNotification) async {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID, actions: [reply],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: MentionAlert.categoryID, actions: [reply],
                intentIdentifiers: [], options: []),
        ])
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = note.isMention ? MentionAlert.categoryID : Self.categoryID
        content.sound = note.sound ? MentionAlert.sound(isMention: note.isMention).unSound : nil
        content.threadIdentifier = note.threadIdentifier
        if let subtitle = note.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.userInfo = [
            Self.chatIDKey: note.chatID,
            Self.msgIDKey: note.id,
        ]
        let req = UNNotificationRequest(
            identifier: note.id, content: content, trigger: nil)
        try? await center.add(req)
    }

    public func delivered() async -> [PostedNotification] {
        await center.deliveredNotifications().compactMap { n in
            let info = n.request.content.userInfo
            guard let chat = info[Self.chatIDKey] as? String else { return nil }
            let content = n.request.content
            let elevated = content.categoryIdentifier == MentionAlert.categoryID
            return PostedNotification(
                id: n.request.identifier, chatID: chat,
                title: content.title, body: content.body,
                isMention: elevated,
                subtitle: content.subtitle.isEmpty ? nil : content.subtitle)
        }
    }
}

/// In-memory backend (tests): post appends, delivered replays the log.
public actor FakeNotificationCenter: NotificationPosting {
    public private(set) var posted: [PostedNotification] = []
    public private(set) var authRequests = 0

    public init() {}

    public func requestAuthorization() async throws -> Bool {
        authRequests += 1
        return true
    }

    public func post(_ note: PostedNotification) async {
        posted.append(note)
    }

    public func delivered() async -> [PostedNotification] {
        posted
    }
}

/// Where a notification interaction routes.
public enum NotificationRoute: Sendable, Equatable {
    case open(chatID: String)
    case reply(chatID: String, text: String)
    case none
}

/// Front: gate + post + response routing. The app owns one and calls
/// handle from handleRealtime; tests inject the fake backend.
@MainActor
public final class MessageNotifications: ObservableObject {
    /// UserDefaults key for the persisted banner toggle (Settings →
    /// Notifications). Absent = first launch = on.
    public static let enabledKey = "notif.enabled"
    /// Persisted message-preview toggle. Absent = first launch = on.
    public static let previewKey = "notif.preview"
    /// Persisted banner-sound toggle. Absent = first launch = on.
    public static let soundKey = "notif.sound"
    /// Body shown when previews are off (never message content).
    public static let hiddenPreviewBody = "New message"

    private let backend: any NotificationPosting
    private let delegate = MessageNotificationDelegate()
    private let defaults: UserDefaults
    @Published public private(set) var authorized: Bool?
    /// Banner toggle (Settings binds here; persisted). Gates `handle`;
    /// AppState's rules path checks it too, so OFF silences all banners.
    @Published public var enabled = true {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    /// Preview toggle (Settings binds here; persisted). Off = banners
    /// show who wrote, never the text.
    @Published public var showPreview = true {
        didSet { defaults.set(showPreview, forKey: Self.previewKey) }
    }
    /// Sound toggle (Settings binds here; persisted). Off = banners
    /// post silent (both banner paths read this).
    @Published public var sound = true {
        didSet { defaults.set(sound, forKey: Self.soundKey) }
    }

    /// Nonisolated so views can take a default `MessageNotifications()`
    /// in their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        backend: (any NotificationPosting)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.backend = backend ?? SystemNotificationCenter()
        self.defaults = defaults
        var enabled = true
        if defaults.object(forKey: Self.enabledKey) != nil {
            enabled = defaults.bool(forKey: Self.enabledKey)
        }
        var showPreview = true
        if defaults.object(forKey: Self.previewKey) != nil {
            showPreview = defaults.bool(forKey: Self.previewKey)
        }
        var sound = true
        if defaults.object(forKey: Self.soundKey) != nil {
            sound = defaults.bool(forKey: Self.soundKey)
        }
        _enabled = Published(initialValue: enabled)
        _showPreview = Published(initialValue: showPreview)
        _sound = Published(initialValue: sound)
        _authorized = Published(initialValue: nil)
    }

    /// Install the response delegate (retained here) on the real center.
    /// Safe to call with the fake backend (only touches the center).
    public func attach(center: UNUserNotificationCenter = .current()) {
        center.delegate = delegate
    }

    public func requestAuthorization() async {
        authorized = (try? await backend.requestAuthorization()) ?? false
    }

    /// One realtime event: gate, then post. Never throws — a failed
    /// post is invisible (the bubble/list already updated). Muted chats
    /// (Settings per-chat overrides) never post here either — the
    /// rules path skips them via ChatFilter, this path via the set.
    /// When the caller passes the rules `decision`, a skip suppresses
    /// the banner too (mute/DND/quiet/keyword/type/edit/noisy) — the
    /// rules path owns that verdict, this path only formats it.
    public func handle(
        _ msg: RealtimeMessage, chatName: String? = nil,
        openChatID: String? = nil, ownDisplayName: String? = nil,
        screenLocked: Bool = false, mutedChatIDs: Set<String> = [],
        decision: ChatFilter.Decision? = nil
    ) async {
        guard enabled else { return }
        if let decision, case .skip = decision { return }
        guard !mutedChatIDs.contains(msg.chatID) else { return }
        guard let note = Self.makeNotification(
            for: msg, chatName: chatName,
            openChatID: openChatID, ownDisplayName: ownDisplayName,
            screenLocked: screenLocked, showPreview: showPreview)
        else { return }
        await backend.post(PostedNotification(
            id: note.id, chatID: note.chatID, title: note.title,
            body: note.body, threadIdentifier: note.threadIdentifier, sound: sound,
            isMention: note.isMention, subtitle: note.subtitle))
    }

    /// Pure gate + format. Nil = suppressed (edit, own message, or the
    /// chat is already open — its bubbles updated in place instead).
    /// Locked screens redact to generic title/body (no sender/text leak).
    /// `showPreview` false hides the text (title still names who/where).
    /// Mentioning messages (owner by display name, or channel/team/
    /// everyone) flag elevated for the OM_MENTION banner style.
    nonisolated public static func makeNotification(
        for msg: RealtimeMessage, chatName: String? = nil,
        openChatID: String? = nil, ownDisplayName: String? = nil,
        screenLocked: Bool = false, showPreview: Bool = true
    ) -> PostedNotification? {
        if msg.isEdit { return nil }
        if let own = ownDisplayName, msg.sender == own { return nil }
        if let open = openChatID, msg.chatID == open { return nil }
        if screenLocked {
            return PostedNotification(
                id: msg.msgId, chatID: msg.chatID,
                title: NcDelivery.redactedTitle, body: NcDelivery.redactedBody)
        }
        let title: String
        if let name = chatName, !name.isEmpty, name != msg.sender {
            title = "\(msg.sender) in \(name)"
        } else {
            title = msg.sender
        }
        let mined = msg.mentions
        let ownerHit = Mentions.mentionsOwner(
            mined, ownerMRI: nil, ownerDisplayName: ownDisplayName ?? "")
        let channelHit = Mentions.mentionsChannelOrEveryone(mined)
        return PostedNotification(
            id: msg.msgId, chatID: msg.chatID, title: title,
            body: showPreview ? msg.text : hiddenPreviewBody,
            isMention: ownerHit || channelHit,
            subtitle: MentionAlert.subtitle(ownerMention: ownerHit, channelMention: channelHit))
    }

    /// Delivered-log readback (banner proof in the app, assertions in tests).
    public func delivered() async -> [PostedNotification] {
        await backend.delivered()
    }

    /// Map a center response to a route + Foundation broadcast.
    /// Returns the route (tests assert it directly). Routes both banner
    /// families the app posts: MessageNotifications banners (`chatID`)
    /// and rules-posted Notifier banners (`OMChatID`) — the app hosts
    /// this delegate alone, so both must resolve here or clicks die.
    /// Routes through the shared NcDelivery map.
    @discardableResult
    nonisolated public static func dispatch(
        actionID: String, userInfo: [AnyHashable: Any], replyText: String? = nil
    ) -> NotificationRoute {
        switch NcDelivery.route(actionID: actionID, userInfo: userInfo, replyText: replyText) {
        case .reply(let chat, let text):
            NotificationCenter.default.post(
                name: .omNotifReply, object: nil,
                userInfo: ["chatID": chat, "text": text])
            return .reply(chatID: chat, text: text)
        case .open(let chat):
            NotificationCenter.default.post(
                name: .omNotifOpenChat, object: nil, userInfo: ["chatID": chat])
            return .open(chatID: chat)
        case .none:
            return .none
        }
    }

    /// Rules-posted banner content. Pure (tests assert it directly).
    /// Meeting-start reasons synthesize "Meeting starting: <chat>" (raw
    /// beacons/blobs never shown); otherwise "sender in chat" (sender
    /// alone when the chat has no better name; 1:1 chats collapse "X in
    /// X" to "X"). The live banner path maps titles/bodies via NcDelivery
    /// (plus preview/sound/lock/elevation) but does NOT collapse 1:1
    /// "X in X" yet — open follow-up, see the waveF merge report.
    nonisolated public static func makeRulesNote(
        for msg: RealtimeMessage, chatName: String, reason: String
    ) -> PostedNotification {
        let title: String
        let body: String
        if reason == ChatFilter.meetingStartingReason {
            if chatName.isEmpty || chatName == msg.chatID {
                title = "Teams meeting"
                body = "Meeting starting"
            } else {
                title = chatName
                body = "Meeting starting: \(chatName)"
            }
        } else if chatName.isEmpty || chatName == msg.chatID {
            title = msg.sender.isEmpty ? "Teams message" : msg.sender
            body = msg.text
        } else if msg.sender.isEmpty {
            title = chatName
            body = msg.text
        } else if chatName == msg.sender {
            // 1:1 chat: the chat name IS the sender — no "X in X".
            title = msg.sender
            body = msg.text
        } else {
            title = "\(msg.sender) in \(chatName)"
            body = msg.text
        }
        return PostedNotification(
            id: msg.msgId, chatID: msg.chatID, title: title, body: body)
    }
}

/// Center delegate: click/reply route through MessageNotifications;
/// banners show even when the app is frontmost (posts were already
/// gated to non-open chats, so nothing double-announces).
public final class MessageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let text = (response as? UNTextInputNotificationResponse)?.userText
        MessageNotifications.dispatch(
            actionID: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            replyText: text)
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
