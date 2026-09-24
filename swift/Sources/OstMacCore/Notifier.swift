// Notifier.swift — om-rules lane: native notification delivery.
//
// Port of TeamsNotifier's Notifier (title/body/sound, Reply + Open chat
// actions), adapted for OstMac:
// - Category ids are OM_* (no TeamsNotifier overlap on shared machines).
// - Two categories: with Reply (when onReply is wired) and open-only
//   (when it is not) — an unwired Reply button never shows.
// - Click opens the chat (om-nc-delivery); only chat-less system/test
//   notifs keep the TeamsNotifier click-copies-body behavior.
// - No logging (observability skipped): post failures are silent.
import AppKit
import Foundation
import UserNotifications

/// Notification category/action/userInfo for message banners. userInfo
/// carries the chat id so the action handlers know where to reply/open.
public enum OmReplyInfo {
    public static let categoryID = "OM_MESSAGE"
    public static let categoryNoReplyID = "OM_MESSAGE_NOREPLY"
    public static let replyActionID = "OM_REPLY"
    public static let chatIDKey = "OMChatID"
    /// Second action next to Reply: opens the chat in the app.
    public static let openActionID = "OM_OPEN_CHAT"
    public static let openActionTitle = "Open chat"
    /// Action button title: banner/alert hover + NC expanded. Keep "Reply".
    public static let actionTitle = "Reply"
    /// Inline-reply send button title (expanded UI).
    public static let sendButtonTitle = "Send"
    /// Inline-reply field placeholder (expanded UI).
    public static let textInputPlaceholder = "Type a reply…"

    public static func userInfo(chatID: String) -> [String: String] {
        [chatIDKey: chatID]
    }

    /// Tolerant read: this backend's key plus om-notif's "chatID",
    /// so banners route whichever backend posted them.
    public static func chatID(from userInfo: [AnyHashable: Any]) -> String? {
        NcDelivery.chatID(from: userInfo)
    }
}

/// Native notifications. Title = "sender in chat" (or sender when the chat
/// has no better name). Body = full message text. Sound on. Banners group
/// by thread (threadIdentifier = chatID) and redact to generic text while
/// the screen is locked. Click / Open chat foregrounds the chat via
/// onOpenChat; Reply (text-input) posts via onReply. When onReply is nil
/// the banner offers Open chat only.
/// Sticky banners: owner sets Alerts style in System Settings > Notifications.
public final class Notifier: NSObject, @unchecked Sendable {
    public static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    /// Reply sender, wired by the app. Result failure text is surfaced as
    /// a loud system notification. Nil = no Reply button offered.
    public var onReply: (@Sendable (String, String) async -> Result<Void, Error>)?

    /// Open-chat handler, wired by the app.
    public var onOpenChat: (@Sendable (String) async -> Void)?

    /// Screen-lock probe (om-nc-delivery). Nil = live CGSession read;
    /// tests inject a stub. Locked message banners redact title+body.
    public var lockCheck: (@Sendable () -> Bool)?

    private override init() {
        super.init()
    }

    public func setup() {
        center.delegate = self
        // Reply affordance: text-input action, minimal options (no
        // .foreground/.destructive/.authenticationRequired — any of those
        // hides or degrades the button). Explicit placeholder: the SDK
        // default is empty, which leaves the expanded field unlabeled.
        let reply = UNTextInputNotificationAction(
            identifier: OmReplyInfo.replyActionID,
            title: OmReplyInfo.actionTitle,
            options: [],
            textInputButtonTitle: OmReplyInfo.sendButtonTitle,
            textInputPlaceholder: OmReplyInfo.textInputPlaceholder)
        // Open chat: foregrounds the app so the conversation appears
        // above the owner's work.
        let open = UNNotificationAction(
            identifier: OmReplyInfo.openActionID,
            title: OmReplyInfo.openActionTitle,
            options: [.foreground])
        let message = UNNotificationCategory(
            identifier: OmReplyInfo.categoryID, actions: [reply, open],
            intentIdentifiers: [], options: [])
        let messageNoReply = UNNotificationCategory(
            identifier: OmReplyInfo.categoryNoReplyID, actions: [open],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([message, messageNoReply])
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Full per-setting state (alert/sound/badge + style). Authorization can
    /// read authorized while the app is switched off in Settings.
    public func settings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    /// chatID attaches the message actions + thread grouping (banners
    /// stack per thread). Locked message banners redact to generic text.
    /// Nil (system/test notifs) posts a plain notification with no action.
    /// `sound` false posts silent (Settings → Sound, via the caller).
    public func post(title: String, body: String, id: String? = nil, chatID: String? = nil, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(no text content)" : body
        content.sound = sound ? .default : nil
        if let chatID, !chatID.isEmpty {
            content.categoryIdentifier = onReply == nil ? OmReplyInfo.categoryNoReplyID : OmReplyInfo.categoryID
            content.userInfo = OmReplyInfo.userInfo(chatID: chatID)
            content.threadIdentifier = chatID
            if lockCheck?() ?? NcDelivery.isScreenLocked() {
                content.title = NcDelivery.redactedTitle
                content.body = NcDelivery.redactedBody
            }
        }
        let req = UNNotificationRequest(
            identifier: id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(req)
    }

    public func postSystem(title: String, body: String) {
        post(title: title, body: body, id: "system-\(title)")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Shared route: Reply posts, banner click / Open-chat opens.
        let text = (response as? UNTextInputNotificationResponse)?.userText
        switch NcDelivery.route(
            actionID: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            replyText: text)
        {
        case .reply(let chatID, _):
            if let textResponse = response as? UNTextInputNotificationResponse {
                await handleReply(textResponse, chatID: chatID)
            }
            return
        case .open(let chatID):
            await onOpenChat?(chatID)
            return
        case .none:
            break
        }
        // Unrouted clicks on system/test notifs (no chat) copy the body;
        // message banners never copy (click opens, dismiss is silent).
        let info = response.notification.request.content.userInfo
        guard OmReplyInfo.chatID(from: info) == nil else { return }
        let body = response.notification.request.content.body
        guard !body.isEmpty else { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
        }
    }

    private func handleReply(_ response: UNTextInputNotificationResponse, chatID: String) async {
        let text = response.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let onReply else { return }
        switch await onReply(chatID, text) {
        case .success:
            break
        case .failure(let err):
            postSystem(title: "OstMac: reply failed", body: "Reply failed: \(err.localizedDescription)")
        }
    }

    // Show banners even while the app is frontmost. .list keeps the
    // foreground copy in Notification Center too, where the Reply button
    // sits expanded. No API forces always-visible buttons; hover
    // (banner/alert) + expanded NC is the macOS ceiling.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
