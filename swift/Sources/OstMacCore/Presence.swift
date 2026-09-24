// Presence.swift — om-presence lane: own status + chatmate presence.
//
// ost parity: TUI LoadPresence (own availability/activity, failure is
// non-critical) + CLI set (available/busy/dnd/away/offline). ost has no
// per-user fetch — its sidebar `online` is hardcoded false — so chatmate
// presence is a new core primitive (Graph /users/{id}/presence) behind
// the same envelope shape.
//
//   let store = PresenceStore()          // live core fetchers
//   await store.refreshOwn()             // own dot (status bar, picker)
//   store.set(status: .busy)             // own-status picker action
//   await store.refreshPeers(ids: [...]) // chatmate dots by user id
//   await store.refreshChatPeerMri(chatID: "19:..", mri: "8:orgid:..") // dots by sender MRI
// Tests inject mock fetchers (same seam as ChatListViewModel.Fetcher).
import DietDesign
import Foundation
import SwiftUI

/// The five settable statuses (ost CLI `--set` values, verbatim).
public enum PresenceStatus: String, CaseIterable, Sendable {
    case available, busy, dnd, away, offline

    /// Picker label.
    public var title: String {
        switch self {
        case .available: "Available"
        case .busy: "Busy"
        case .dnd: "Do not disturb"
        case .away: "Away"
        case .offline: "Appear offline"
        }
    }

    /// Server availability the core reports back after a successful set
    /// (ost status table: dnd → DoNotDisturb).
    public var availability: String {
        switch self {
        case .available: "Available"
        case .busy: "Busy"
        case .dnd: "DoNotDisturb"
        case .away: "Away"
        case .offline: "Offline"
        }
    }

    /// Best-effort reverse map of a server availability to a picker row.
    /// Unknown/future values collapse to nil (picker shows no selection).
    public static func from(availability: String) -> PresenceStatus? {
        switch availability {
        case "Available": .available
        case "Busy": .busy
        case "DoNotDisturb": .dnd
        case "Away": .away
        case "Offline": .offline
        default: nil
        }
    }
}

/// Pure availability helpers (ost TUI rules + Teams dot colors).
public enum PresenceFormat {
    /// ost TUI `is_online`: anything but Offline/PresenceUnknown.
    public static func isOnline(availability: String) -> Bool {
        availability != "Offline" && availability != "PresenceUnknown"
    }

    /// Dot color for a server availability (unknown → gray).
    /// Same tokens as DietPresence.color (DND is purple, not red).
    public static func color(availability: String) -> Color {
        switch availability {
        case "Available": Color(nsColor: DietColor.presenceAvailable)
        case "Busy": Color(nsColor: DietColor.presenceBusy)
        case "DoNotDisturb": Color(nsColor: DietColor.presenceDND)
        case "Away", "BeRightBack": Color(nsColor: DietColor.presenceAway)
        default: Color(nsColor: DietColor.presenceOffline) // Offline, PresenceUnknown, future values
        }
    }

    /// One-line status text (ost status bar shows "Status: {availability}"
    /// when offline; we always show the availability + activity).
    public static func label(availability: String, activity: String) -> String {
        availability == activity || activity.isEmpty
            ? availability : "\(availability) · \(activity)"
    }
}

public extension DietPresence {
    /// Map a server availability to a system presence dot.
    /// Unknown/future values + nil collapse to nil (no dot, fail closed).
    public init?(teamsAvailability: String?) {
        switch teamsAvailability {
        case "Available": self = .available
        case "Busy": self = .busy
        case "DoNotDisturb": self = .dnd
        case "Away", "BeRightBack": self = .away
        case "Offline": self = .offline
        default: return nil
        }
    }
}

/// Own status + chatmate cache. All fetches run off-main (blocking FFI).
@MainActor
public final class PresenceStore: ObservableObject {
    public typealias OwnFetcher = @Sendable () throws -> PresenceResponse
    public typealias SetFetcher = @Sendable (String) throws -> PresenceResponse
    public typealias UserFetcher = @Sendable (String) throws -> UserPresenceResponse
    public typealias ResolveFetcher = @Sendable (String) throws -> ResolveMriResponse

    /// Last known own presence; nil until the first successful refresh.
    @Published public private(set) var own: PresenceResponse?
    /// Chatmate presence by user id (Entra ID or UPN).
    @Published public private(set) var peers: [String: UserPresenceResponse] = [:]
    /// Chatmate presence by 1:1 chat id (row/header dot source). Core
    /// ChatInfo carries no peer ids (ost upstream gap), so live entries
    /// land here via `refreshChatPeer` (known user id) or
    /// `refreshChatPeerMri` (sender MRI learned from the realtime feed);
    /// demo/tests adopt directly.
    @Published public private(set) var chatPeers: [String: UserPresenceResponse] = [:]
    /// Last failure (fetch or set); cleared on the next success.
    /// Like ost, presence failure is non-critical: the UI keeps stale data.
    @Published public private(set) var error: String?
    @Published public private(set) var setting = false
    /// Resolved Graph users by MRI (om-steal-ids: one resolve per mate).
    public private(set) var resolved: [String: ResolveMriResponse] = [:]
    /// Learned sender MRI by 1:1 chat id.
    public private(set) var mriByChat: [String: String] = [:]
    /// Min seconds between MRI refreshes of one chat (realtime feeds can
    /// burst; tests shrink it). Resolve cache makes repeats cheap anyway.
    public var resolveThrottle: TimeInterval = 300

    private let ownFetcher: OwnFetcher
    private let setFetcher: SetFetcher
    private let userFetcher: UserFetcher
    private let resolveFetcher: ResolveFetcher
    private var lastResolve: [String: Date] = [:]

    /// Nonisolated so views can take a default `PresenceStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        ownFetcher: @escaping OwnFetcher = { try RustCore.presence() },
        setFetcher: @escaping SetFetcher = { try RustCore.setPresence(status: $0) },
        userFetcher: @escaping UserFetcher = { try RustCore.userPresence(id: $0) },
        resolveFetcher: @escaping ResolveFetcher = { try RustCore.resolveMri(mri: $0) }
    ) {
        self.ownFetcher = ownFetcher
        self.setFetcher = setFetcher
        self.userFetcher = userFetcher
        self.resolveFetcher = resolveFetcher
    }

    /// Refresh own presence. Failure keeps the stale value (ost parity).
    public func refreshOwn() async {
        let fetcher = ownFetcher
        do {
            let resp = try await Task.detached { try fetcher() }.value
            own = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Fire-and-forget own refresh (status bar, post-gate startup).
    public func refreshOwnSoon() {
        Task { await refreshOwn() }
    }

    /// Set own status (picker action). Applies the server-echoed value.
    public func set(status: PresenceStatus) {
        guard !setting else { return }
        setting = true
        let fetcher = setFetcher
        let want = status.rawValue
        Task {
            defer { setting = false }
            do {
                let resp = try await Task.detached { try fetcher(want) }.value
                own = resp
                error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// Adopt one presence without core (tests, previews, demo).
    public func adoptOwn(_ resp: PresenceResponse) {
        own = resp
        error = nil
    }

    /// Adopt one chatmate presence without core (tests, previews, demo).
    public func adoptPeer(_ resp: UserPresenceResponse) {
        peers[resp.id] = resp
    }

    /// Pin a chatmate presence to a 1:1 chat id (row/header dot source).
    public func adoptChatPeer(chatID: String, response: UserPresenceResponse) {
        chatPeers[chatID] = response
    }

    /// Known availability for a 1:1 chat id, or nil when unknown.
    public func availabilityForChat(_ chatID: String) -> String? {
        chatPeers[chatID]?.availability
    }

    /// Fetch one chatmate by user id and pin it to a 1:1 chat id.
    /// Failure keeps the stale pin (ost non-critical rule).
    public func refreshChatPeer(chatID: String, userID: String) async {
        let fetcher = userFetcher
        do {
            let resp = try await Task.detached { try fetcher(userID) }.value
            peers[resp.id] = resp
            chatPeers[chatID] = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Refresh chatmates by user id. Unknown ids keep stale entries;
    /// per-id failure records `error` but keeps the rest.
    public func refreshPeers(ids: [String]) async {
        let fetcher = userFetcher
        for id in ids {
            do {
                let resp = try await Task.detached { try fetcher(id) }.value
                peers[resp.id] = resp
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// Resolve a sender MRI to a Graph user, then fetch that user's
    /// presence and pin it to a 1:1 chat id. Non-MRIs and non-orgid
    /// forms (skypeids, visitor…) are silent no-ops — nothing to
    /// resolve. Resolves are cached per MRI; refreshes are throttled
    /// per chat. Failure keeps the stale pin (ost non-critical rule).
    public func refreshChatPeerMri(chatID: String, mri: String) async {
        guard Mri.isResolvable(mri) else { return }
        if let last = lastResolve[chatID],
           Date().timeIntervalSince(last) < resolveThrottle
        {
            return
        }
        lastResolve[chatID] = Date()
        let resolve = resolveFetcher
        let fetch = userFetcher
        do {
            let user: ResolveMriResponse
            if let hit = resolved[mri] {
                user = hit
            } else {
                user = try await Task.detached { try resolve(mri) }.value
                resolved[mri] = user
            }
            mriByChat[chatID] = mri
            let resp = try await Task.detached { try fetch(user.id) }.value
            peers[resp.id] = resp
            chatPeers[chatID] = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Adopt one MRI resolution without core (tests, previews, demo).
    public func adoptResolved(mri: String, response: ResolveMriResponse) {
        resolved[mri] = response
    }

    /// Drop everything after sign-out (fail closed; stale dots vanish).
    public func clear() {
        own = nil
        peers = [:]
        chatPeers = [:]
        resolved = [:]
        mriByChat = [:]
        lastResolve = [:]
        error = nil
    }
}

/// Availability dot (sidebar rows, conversation header, status bar).
public struct PresenceDot: View {
    private let availability: String?

    /// Known availability, or nil for unknown (gray hollow).
    public init(availability: String?) {
        self.availability = availability
    }

    public var body: some View {
        if let avail = availability {
            Circle()
                .fill(PresenceFormat.color(availability: avail))
                .frame(
                    width: DietSize.presenceDot,
                    height: DietSize.presenceDot)
                .help(PresenceFormat.label(availability: avail, activity: ""))
        } else {
            Circle()
                .stroke(
                    Color(nsColor: DietColor.presenceOffline),
                    lineWidth: 1.5)
                .frame(
                    width: DietSize.presenceDot,
                    height: DietSize.presenceDot)
                .help("Presence unknown")
        }
    }
}

/// Own-status picker (status bar menu): dot + availability label, five
/// rows + refresh. Nil own = "Unknown" (pre-first-refresh).
public struct PresencePicker: View {
    @ObservedObject private var store: PresenceStore

    public init(store: PresenceStore) {
        self.store = store
    }

    public var body: some View {
        Menu {
            ForEach(PresenceStatus.allCases, id: \.rawValue) { status in
                Button {
                    store.set(status: status)
                } label: {
                    Label(status.title, systemImage: isSelected(status) ? "checkmark" : "")
                }
                .disabled(store.setting)
            }
            Divider()
            Button("Refresh status") { store.refreshOwnSoon() }
        } label: {
            HStack(spacing: 4) {
                PresenceDot(availability: store.own?.availability)
                Text(store.own.map { PresenceFormat.label(availability: $0.availability, activity: $0.activity) } ?? "Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Set your Teams presence")
        .disabled(store.setting)
    }

    private func isSelected(_ status: PresenceStatus) -> Bool {
        store.own.map { PresenceStatus.from(availability: $0.availability) == status } ?? false
    }
}
