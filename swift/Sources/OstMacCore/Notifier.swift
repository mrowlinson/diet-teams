// Notifier.swift — om-rules lane: native notification delivery.
//
// Port of TeamsNotifier's Notifier (title/body/sound, Reply + Open chat
// actions, click-copies-body), adapted for OstMac:
// - Category ids are OM_* (no TeamsNotifier overlap on shared machines).
// - Two categories: with Reply (when onReply is wired) and open-only
//   (when it is not) — an unwired Reply button never shows.
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

    public static func chatID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo[chatIDKey] as? String, !id.isEmpty else { return nil }
        return id
    }
}

/// Native notifications. Title = "sender in chat" (or sender when the chat
/// has no better name). Body = full message text. Sound on. Click = copy
/// body to clipboard. Message notifications carry Reply (text-input, posts
/// via onReply) and Open chat (foregrounds the chat via onOpenChat);
/// when onReply is nil the banner offers Open chat only.
/// Sticky banners: owner sets Alerts style in System Settings > Notifications.
public final class Notifier: NSObject, @unchecked Sendable {
    public static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    /// Reply sender, wired by the app. Result failure text is surfaced as
    /// a loud system notification. Nil = no Reply button offered.
    public var onReply: (@Sendable (String, String) async -> Result<Void, Error>)?

    /// Open-chat handler, wired by the app.
    public var onOpenChat: (@Sendable (String) async -> Void)?

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

    /// chatID attaches the message actions + thread id. Nil (system/test
    /// notifs) posts a plain notification with no action.
    public func post(title: String, body: String, id: String? = nil, chatID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(no text content)" : body
        content.sound = .default
        if let chatID, !chatID.isEmpty {
            content.categoryIdentifier = onReply == nil ? OmReplyInfo.categoryNoReplyID : OmReplyInfo.categoryID
            content.userInfo = OmReplyInfo.userInfo(chatID: chatID)
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
        // Reply action: POST the text to the thread. Silent on success,
        // loud system notification on failure. Never copies.
        if response.actionIdentifier == OmReplyInfo.replyActionID,
           let textResponse = response as? UNTextInputNotificationResponse
        {
            await handleReply(textResponse)
            return
        }
        // Open-chat action: show (or focus) the chat. Never copies.
        if response.actionIdentifier == OmReplyInfo.openActionID {
            let info = response.notification.request.content.userInfo
            if let chatID = OmReplyInfo.chatID(from: info) {
                await onOpenChat?(chatID)
            }
            return
        }
        // Any other click/dismiss-with-action copies the body (unchanged).
        let body = response.notification.request.content.body
        guard !body.isEmpty else { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
        }
    }

    private func handleReply(_ response: UNTextInputNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let chatID = OmReplyInfo.chatID(from: info) else { return }
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
