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
// Tests inject mock fetchers (same seam as ChatListViewModel.Fetcher).
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
    public static func color(availability: String) -> Color {
        switch availability {
        case "Available": .green
        case "Busy", "DoNotDisturb": .red
        case "Away", "BeRightBack": .yellow
        default: .gray // Offline, PresenceUnknown, future values
        }
    }

    /// One-line status text (ost status bar shows "Status: {availability}"
    /// when offline; we always show the availability + activity).
    public static func label(availability: String, activity: String) -> String {
        availability == activity || activity.isEmpty
            ? availability : "\(availability) · \(activity)"
    }
}

/// Own status + chatmate cache. All fetches run off-main (blocking FFI).
@MainActor
public final class PresenceStore: ObservableObject {
    public typealias OwnFetcher = @Sendable () throws -> PresenceResponse
    public typealias SetFetcher = @Sendable (String) throws -> PresenceResponse
    public typealias UserFetcher = @Sendable (String) throws -> UserPresenceResponse

    /// Last known own presence; nil until the first successful refresh.
    @Published public private(set) var own: PresenceResponse?
    /// Chatmate presence by user id (Entra ID or UPN).
    @Published public private(set) var peers: [String: UserPresenceResponse] = [:]
    /// Chatmate presence by 1:1 chat id (row/header dot source). Core
    /// ChatInfo carries no peer ids (ost upstream gap), so live entries
    /// land here only via `refreshChatPeer`; demo/tests adopt directly.
    @Published public private(set) var chatPeers: [String: UserPresenceResponse] = [:]
    /// Last failure (fetch or set); cleared on the next success.
    /// Like ost, presence failure is non-critical: the UI keeps stale data.
    @Published public private(set) var error: String?
    @Published public private(set) var setting = false

    private let ownFetcher: OwnFetcher
    private let setFetcher: SetFetcher
    private let userFetcher: UserFetcher

    /// Nonisolated so views can take a default `PresenceStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        ownFetcher: @escaping OwnFetcher = { try RustCore.presence() },
        setFetcher: @escaping SetFetcher = { try RustCore.setPresence(status: $0) },
        userFetcher: @escaping UserFetcher = { try RustCore.userPresence(id: $0) }
    ) {
        self.ownFetcher = ownFetcher
        self.setFetcher = setFetcher
        self.userFetcher = userFetcher
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

    /// Drop everything after sign-out (fail closed; stale dots vanish).
    public func clear() {
        own = nil
        peers = [:]
        chatPeers = [:]
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
                .frame(width: 8, height: 8)
                .help(PresenceFormat.label(availability: avail, activity: ""))
        } else {
            Circle()
                .stroke(.gray, lineWidth: 1.5)
                .frame(width: 8, height: 8)
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
