// Typing.swift — om-typing lane: realtime typing indicators.
//
// The Rust core surfaces Skype/Teams `Control/Typing` frames as `typing[]`
// on the typed poll envelope; the RealtimeFeed forwards them (no dedupe —
// repeats are the keepalive). This store holds them per thread with a
// timeout, and the timeline shows a native "who is typing" row.
//
//   feed.onTyping { [weak self] ev in
//       Task { @MainActor [weak self] in self?.typing.ingest(ev) } }
//
// No polling (rides the existing feed), no chat-list refresh (typing never
// touches the list — the row is the only surface, counters in Diagnostics).
import DietDesign
import Foundation
import SwiftUI

/// Pure "who is typing" line (timeline row + tests share it).
public enum TypingFormat {
    /// Nil when nobody is typing; sorted display names in.
    public static func line(names: [String]) -> String? {
        switch names.count {
        case 0:
            nil
        case 1:
            "\(names[0]) is typing…"
        case 2:
            "\(names[0]) and \(names[1]) are typing…"
        case 3:
            "\(names[0]), \(names[1]) and \(names[2]) are typing…"
        default:
            "\(names[0]), \(names[1]) and \(names.count - 2) others are typing…"
        }
    }
}

/// Per-thread typing state with timeout expiry. Main-actor (SwiftUI-owned).
@MainActor
public final class TypingStore: ObservableObject {
    /// One live indicator: display name + last event time.
    public struct Entry: Sendable, Equatable {
        public let displayName: String
        public let lastSeen: Date
    }

    /// Live indicators by chat id, keyed by sender MRI (or display name
    /// when the event carried no MRI).
    @Published public private(set) var byChat: [String: [String: Entry]] = [:]

    /// Seconds an indicator survives without a refresh (tests shrink it).
    public var timeout: TimeInterval = 8

    private var timer: Timer?

    /// Nonisolated so views can take a default `TypingStore()` in their
    /// (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init() {}

    /// Record one typing event (refreshes that sender's timeout). Empty
    /// chat ids and empty senders are ignored (nothing to attribute).
    public func ingest(_ event: TypingEvent, at now: Date = Date()) {
        guard !event.chatID.isEmpty, !event.sender.isEmpty else { return }
        let key = event.senderID ?? event.sender
        var thread = byChat[event.chatID] ?? [:]
        thread[key] = Entry(displayName: event.sender, lastSeen: now)
        byChat[event.chatID] = thread
        ensureTimer()
    }

    /// A real message supersedes that sender's indicator (the bubble is
    /// the typing resolved). Unknown senders are a no-op.
    public func noteMessage(chatID: String, sender: String, senderID: String? = nil) {
        guard var thread = byChat[chatID] else { return }
        if let sid = senderID { thread.removeValue(forKey: sid) }
        for key in thread.keys where thread[key]?.displayName == sender {
            thread.removeValue(forKey: key)
        }
        if thread.isEmpty {
            byChat.removeValue(forKey: chatID)
        } else {
            byChat[chatID] = thread
        }
    }

    /// Sorted display names still typing in a chat (expired excluded).
    /// Nil (nothing open) yields none.
    public func typists(chatID: String?, at now: Date = Date()) -> [String] {
        guard let id = chatID, let thread = byChat[id] else { return [] }
        return thread.values
            .filter { now.timeIntervalSince($0.lastSeen) < timeout }
            .map(\.displayName)
            .sorted()
    }

    /// Timeline row text for a chat, or nil when nobody is typing.
    public func line(chatID: String?, at now: Date = Date()) -> String? {
        TypingFormat.line(names: typists(chatID: chatID, at: now))
    }

    /// Live indicators across all chats (Diagnostics counter source).
    public var activeCount: Int {
        let now = Date()
        return byChat.values
            .flatMap(\.values)
            .filter { now.timeIntervalSince($0.lastSeen) < timeout }
            .count
    }

    /// Drop expired indicators (the 1s timer drives this while any chat
    /// holds state; tests drive it with explicit dates).
    public func prune(at now: Date = Date()) {
        var next = byChat
        for (chat, thread) in next {
            let kept = thread.filter { now.timeIntervalSince($0.value.lastSeen) < timeout }
            if kept.isEmpty {
                next.removeValue(forKey: chat)
            } else {
                next[chat] = kept
            }
        }
        byChat = next
        if next.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Drop everything after sign-out (fail closed; stale rows vanish).
    public func clear() {
        byChat = [:]
        timer?.invalidate()
        timer = nil
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prune() }
        }
    }
}

/// Native typing row: animated three-dot ellipsis + "who is typing" line.
/// Lives at the timeline tail (above the compose box), only while the open
/// chat holds live indicators.
public struct TypingIndicatorView: View {
    public let line: String

    public init(line: String) {
        self.line = line
    }

    public var body: some View {
        HStack(spacing: DietSpace.xs) {
            TypingDots()
            Text(line)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .lineLimit(1)
        }
        .accessibilityLabel(line)
    }
}

/// Three-dot bounce (one bright dot cycling, native caption styling).
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 3.0)) { context in
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(DietColor.textSecondaryColor)
                        .frame(width: 4, height: 4)
                        .opacity(Self.opacity(
                            date: context.date, index: i))
                }
            }
        }
    }

    /// Wave phase from wall time: the bright dot advances 3×/second.
    static func opacity(date: Date, index: Int) -> Double {
        let phase = Int(date.timeIntervalSinceReferenceDate * 3) % 3
        return phase == index ? 1.0 : 0.3
    }
}
