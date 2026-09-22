// OstMacConv — om-conv lane demo shell: one conversation window.
// Usage:
//   OstMacConv --demo [--say <text>]     canned messages, no sign-in
//                                        (--say auto-sends once, demo only)
//   OstMacConv --demo-rich [--say <text>] rich canned states (om-convrich):
//                                        mentions, code, edited, failed, 2 days
//   OstMacConv --chat <id> [--name <n>]  real history via core
import OstMacCore
import SwiftUI

@main
struct ConvApp: App {
    @StateObject private var store: ConversationStore
    private let initialChatID: String?
    private let initialChatName: String?
    private let demoSay: String?

    init() {
        let args = CommandLine.arguments
        if args.contains("--demo-rich") {
            _store = StateObject(wrappedValue: .demoRich())
            initialChatID = nil
            initialChatName = nil
            if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
                demoSay = args[i + 1]
            } else {
                demoSay = nil
            }
        } else if args.contains("--demo") {
            _store = StateObject(wrappedValue: .demo())
            initialChatID = nil
            initialChatName = nil
            if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
                demoSay = args[i + 1]
            } else {
                demoSay = nil
            }
        } else if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            let id = args[i + 1]
            var name: String?
            if let j = args.firstIndex(of: "--name"), j + 1 < args.count {
                name = args[j + 1]
            }
            _store = StateObject(wrappedValue: ConversationStore())
            initialChatID = id
            initialChatName = name
            demoSay = nil
        } else {
            _store = StateObject(wrappedValue: ConversationStore())
            initialChatID = nil
            initialChatName = nil
            demoSay = nil
        }
    }

    var body: some Scene {
        WindowGroup("OstMac Conversation") {
            ConversationView(store: store)
                .task {
                    if let id = initialChatID {
                        store.open(chatID: id, chatName: initialChatName)
                    } else if let say = demoSay {
                        store.send(text: say)
                    }
                }
        }
        .defaultSize(width: 480, height: 640)
    }
}
