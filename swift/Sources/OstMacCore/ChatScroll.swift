// ChatScroll.swift — om-scroll: follow/pill policy + per-chat scroll state.
//
// Autoscroll fires ONLY while the viewport hugs the tail (near bottom);
// anywhere else, incoming mail lands in a new-message pill instead of
// yanking the reader. Own echoes always follow (the Send tap already
// implies the jump). History prepends hold the first-visible row, the
// top load-more is debounced, and the initial landing re-asserts the
// bottom while rows settle (short-land fix).
import Foundation
import SwiftUI

/// Pure scroll decisions (testable without views).
public enum ScrollPolicy {
    /// Follow the tail on advance? Near-bottom always; scrolled-up only
    /// for own echoes (user-initiated; shows the send).
    public static func shouldFollow(nearBottom: Bool, isOwnTail: Bool) -> Bool {
        nearBottom || isOwnTail
    }

    /// Unread tail count past the read frontier. Nil/unknown frontier
    /// (fresh or switched chat) reads 0 — never a stale pill.
    public static func unseenCount(messages: [ChatMessage], after id: String?) -> Int {
        guard let id, let i = messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return max(0, messages.count - (i + 1))
    }

    /// Pill caption for the unread count; nil hides the pill.
    public static func pillTitle(unseen: Int) -> String? {
        guard unseen > 0 else { return nil }
        return unseen == 1 ? "1 new message" : "\(unseen) new messages"
    }

    /// Minimum gap between top load-more fires (the row's onAppear
    /// refires on every prepend/rebuild; without this one scroll to the
    /// top page-churns the whole history).
    public static let loadMoreCooldown: TimeInterval = 2.0

    public static func shouldLoadMore(
        now: Date, lastFire: Date, cooldown: TimeInterval = loadMoreCooldown
    ) -> Bool {
        now.timeIntervalSince(lastFire) >= cooldown
    }

    /// Absolute re-assert offsets (seconds after landing) while the
    /// reader stays near the bottom. Rows grow as images resolve, so
    /// one scroll lands short; these settle passes pin the true bottom.
    public static let settleDelays: [TimeInterval] = [0.35, 1.0, 2.0]
}

/// Live scroll state for one open chat (om-scroll).
///
/// A reference type so delayed settle passes read the CURRENT
/// near-bottom flag — a struct-captured Task would see a stale copy and
/// yank a reader who just scrolled up. The timeline view owns one via
/// `@StateObject` and is `.id()`-keyed by chat, so visible sets and
/// read frontiers never leak across chats.
@MainActor
public final class ChatScrollModel: ObservableObject {
    /// The bottom sentinel is on screen (viewport hugs the tail).
    @Published public var nearBottom = true
    /// Read frontier: tail id at the last bottom dwell. The pill count
    /// derives from it. Published so pill taps re-render.
    @Published public var lastReadID: String?
    /// Last tail id the advance detector consumed.
    public var lastSeenID: String?
    /// Rendered bubble ids (LazyVStack window + buffer).
    public var visibleIDs = Set<String>()
    /// First message id when the last load-more fired (fallback
    /// prepend anchor when the visible set is empty).
    public var prePrependFirstID: String?
    /// In-flight settle passes; cancelled when the reader leaves the
    /// bottom (definitive — no check-then-act race).
    public var settleTask: Task<Void, Never>?
    private var lastLoadMoreFire = Date.distantPast

    public init() {}

    /// Debounced load-more gate: records the fire when allowed.
    public func shouldFireLoadMore(now: Date = Date()) -> Bool {
        guard ScrollPolicy.shouldLoadMore(now: now, lastFire: lastLoadMoreFire) else { return false }
        lastLoadMoreFire = now
        return true
    }

    /// Armed when the reader may auto-page: set on leaving the top,
    /// consumed by any load-more fire. Prepend rebuilds re-trip the
    /// sentinel's onAppear without an excursion, so the armed flag —
    /// not the cooldown alone — is what stops page-chains.
    public var pagingArmed = true

    /// Re-arm auto-paging (the top sentinel left the screen: the next
    /// reach-top is a genuine excursion).
    public func armPaging() {
        pagingArmed = true
    }

    /// Auto-fire gate (primary): armed + debounced. Disarms on fire, so
    /// no second page fires without a new scroll excursion. A debounce
    /// block leaves the arm set (the excursion still counts).
    public func shouldAutoFireLoadMore(now: Date = Date()) -> Bool {
        guard pagingArmed else { return false }
        guard shouldFireLoadMore(now: now) else { return false }
        pagingArmed = false
        return true
    }

    /// Explicit-tap gate (fallback): debounced, needs no arm. Disarms on
    /// fire so the tap's own prepend rebuild cannot auto-chain.
    public func shouldTapLoadMore(now: Date = Date()) -> Bool {
        guard shouldFireLoadMore(now: now) else { return false }
        pagingArmed = false
        return true
    }

    /// First on-screen message in history order (prepend anchor).
    public func firstVisibleID(in messages: [ChatMessage]) -> String? {
        messages.first(where: { visibleIDs.contains($0.id) })?.id
    }

    public func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
    }
}
