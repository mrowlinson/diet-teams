// Notifications.swift — om-notif: macOS user notifications for realtime chat.
//
// Pipeline: the pure gate (edits, own messages, open chat) decides,
// and the backend posts through UNUserNotificationCenter. Click returns
// to the chat via NotificationCenter (.omNotifOpenChat); the message
// category carries an inline reply action (.omNotifReply → core send).
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
public struct PostedNotification: Sendable, Equatable {
    public let id: String // msgId (also the UN request identifier)
    public let chatID: String
    public let title: String
    public let body: String
    public let threadIdentifier: String

    public init(id: String, chatID: String, title: String, body: String, threadIdentifier: String? = nil) {
        self.id = id
        self.chatID = chatID
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier ?? chatID
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
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryID, actions: [reply],
            intentIdentifiers: [], options: [])])
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = note.threadIdentifier
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
            return PostedNotification(
                id: n.request.identifier, chatID: chat,
                title: n.request.content.title, body: n.request.content.body)
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

    private let backend: any NotificationPosting
    private let delegate = MessageNotificationDelegate()
    private let defaults: UserDefaults
    @Published public private(set) var authorized: Bool?
    /// Banner toggle (Settings binds here; persisted). Gates `handle`;
    /// AppState's rules path checks it too, so OFF silences all banners.
    @Published public var enabled = true {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
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
        _enabled = Published(initialValue: enabled)
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
    /// post is invisible (the bubble/list already updated).
    public func handle(
        _ msg: RealtimeMessage, chatName: String? = nil,
        openChatID: String? = nil, ownDisplayName: String? = nil,
        screenLocked: Bool = false
    ) async {
        guard enabled else { return }
        guard let note = Self.makeNotification(
            for: msg, chatName: chatName,
            openChatID: openChatID, ownDisplayName: ownDisplayName,
            screenLocked: screenLocked)
        else { return }
        await backend.post(note)
    }

    /// Pure gate + format. Nil = suppressed (edit, own message, or the
    /// chat is already open — its bubbles updated in place instead).
    /// Locked screens redact to generic title/body (no sender/text leak).
    nonisolated public static func makeNotification(
        for msg: RealtimeMessage, chatName: String? = nil,
        openChatID: String? = nil, ownDisplayName: String? = nil,
        screenLocked: Bool = false
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
        return PostedNotification(
            id: msg.msgId, chatID: msg.chatID, title: title, body: msg.text)
    }

    /// Delivered-log readback (banner proof in the app, assertions in tests).
    public func delivered() async -> [PostedNotification] {
        await backend.delivered()
    }

    /// Map a center response to a route + Foundation broadcast.
    /// Returns the route (tests assert it directly). Routes through the
    /// shared map, so both backend userInfo keys open/reply.
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
