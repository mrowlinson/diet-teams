// NotifTests — om-notif pipeline: gate, post+deliver, click/reply routing.
import UserNotifications
import XCTest

@testable import OstMacCore

final class NotifTests: XCTestCase {
    func realtime(
        chat: String = "19:abc@thread.v2", id: String = "m1",
        sender: String = "Priya Nair", text: String = "hello", edit: Bool = false
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: id, sender: sender,
            text: text, time: "2026-09-23T10:00:00Z",
            isEdit: edit, editedID: edit ? "m0" : nil)
    }

    func testPostsAndDelivers() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake)
        await notifs.handle(realtime(), openChatID: "19:other@thread.v2")
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].id, "m1")
        XCTAssertEqual(posted[0].chatID, "19:abc@thread.v2")
        XCTAssertEqual(posted[0].title, "Priya Nair")
        XCTAssertEqual(posted[0].body, "hello")
        // Delivered log replays the post (banner proof surface).
        let delivered = await notifs.delivered()
        XCTAssertEqual(delivered, posted)
    }

    func testGroupTitleNamesChat() {
        let note = MessageNotifications.makeNotification(
            for: realtime(), chatName: "Design Sync")
        XCTAssertEqual(note?.title, "Priya Nair in Design Sync")
    }

    func testSkipsOwnMessage() {
        let m = realtime(sender: "Me")
        XCTAssertNil(MessageNotifications.makeNotification(for: m, ownDisplayName: "Me"))
    }

    func testSkipsEdit() {
        XCTAssertNil(MessageNotifications.makeNotification(for: realtime(edit: true)))
    }

    func testSkipsOpenChat() {
        let m = realtime()
        XCTAssertNil(MessageNotifications.makeNotification(for: m, openChatID: m.chatID))
    }

    func testDisabledPostsNothing() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake)
        await MainActor.run { notifs.enabled = false }
        await notifs.handle(realtime())
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 0)
    }

    func testRequestAuthorization() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake)
        await notifs.requestAuthorization()
        let authRequests = await fake.authRequests
        XCTAssertEqual(authRequests, 1)
        let authorized = await notifs.authorized
        XCTAssertEqual(authorized, true)
    }

    func testClickRoutesOpen() {
        let r = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["chatID": "19:abc@thread.v2"])
        XCTAssertEqual(r, .open(chatID: "19:abc@thread.v2"))
    }

    func testClickBroadcastsFoundationNote() {
        let exp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:abc@thread.v2"
        }
        MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["chatID": "19:abc@thread.v2"])
        wait(for: [exp], timeout: 1)
    }

    func testReplyRoutes() {
        let exp = expectation(forNotification: .omNotifReply, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["text"] as? String == "yo"
        }
        let r = MessageNotifications.dispatch(
            actionID: SystemNotificationCenter.replyActionID,
            userInfo: ["chatID": "19:x"], replyText: "yo")
        XCTAssertEqual(r, .reply(chatID: "19:x", text: "yo"))
        wait(for: [exp], timeout: 1)
    }

    func testEmptyReplyIsNone() {
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: SystemNotificationCenter.replyActionID,
                userInfo: ["chatID": "19:x"], replyText: ""),
            .none)
    }

    func testDismissAndUnknownAreNone() {
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDismissActionIdentifier,
                userInfo: ["chatID": "19:x"]),
            .none)
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDefaultActionIdentifier, userInfo: [:]),
            .none)
    }
}
