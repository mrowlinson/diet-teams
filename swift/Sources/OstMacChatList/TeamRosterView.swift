// TeamRosterView.swift — om-h5-members lane: team roster (members + owners).
import Combine
import DietDesign
import Foundation
import OstMacCore
import SwiftUI

/// Roster content state (mirrors TeamsState: channels open as
/// conversations but the roster never reorders the browser).
public enum TeamRosterState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty roster in `members`.
    case loaded
    /// Fetch succeeded with zero members.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads one team's roster off the main thread and publishes rows.
///
/// Default fetchers call `RustCore.teamMembers/teamMemberAdd/
/// teamMemberRemove` (blocking FFI + network) on detached tasks.
/// Tests inject mock fetchers.
///
/// Display names come from Graph `displayName` first; blanks fall
/// back to the caller-supplied `names` map (MRI/user-id → name, e.g.
/// adopted from `PresenceStore.resolved` or message senders), then
/// email, then the membership id. See `displayName(for:names:)`.
///
/// Known gaps (not fixed here):
/// - Graph omits/blanks `displayName` for some guests and deleted
///   users; those rows show email or the raw membership id.
/// - The caller MRI map only resolves the `8:orgid:` form
///   (`Mri.isResolvable`); skypeids/visitor/federated ids never
///   resolve and always fall through to email/id.
/// - Guests usually lack `email` and non-AAD entries may lack
///   `userId`; such rows can only show the membership id.
/// - No presence dots: per-member presence fetch is out of scope.
/// - Add/remove need owner rights; a 403 surfaces as the error text.
@MainActor
public final class TeamRosterViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias ListFetcher = @Sendable (String) throws -> TeamMembersResponse
    public typealias AddFetcher = @Sendable (String, String, Bool) throws -> TeamMemberAddResponse
    public typealias RemoveFetcher = @Sendable (String, String) throws -> TeamMemberRemoveResponse

    /// Team this roster belongs to.
    public let teamID: String
    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var members: [TeamMember] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamRosterState = .loading
    /// Caller-supplied name map (MRI or user id → display name).
    /// Adopted from `PresenceStore.resolved` or message senders.
    public var names: [String: String] = [:]

    private let listFetcher: ListFetcher
    private let addFetcher: AddFetcher
    private let removeFetcher: RemoveFetcher

    public init(
        teamID: String,
        listFetcher: @escaping ListFetcher = { try RustCore.teamMembers(teamID: $0) },
        addFetcher: @escaping AddFetcher = { try RustCore.teamMemberAdd(teamID: $0, user: $1, owner: $2) },
        removeFetcher: @escaping RemoveFetcher = { try RustCore.teamMemberRemove(teamID: $0, memberID: $1) }
    ) {
        self.teamID = teamID
        self.listFetcher = listFetcher
        self.addFetcher = addFetcher
        self.removeFetcher = removeFetcher
    }

    /// Display name for one roster entry. Graph `displayName` wins
    /// when non-blank; blank falls back to the caller map (keyed by
    /// user id or `8:orgid:` MRI), then email, then the membership
    /// id. Pure helper so tests pin the fallback chain.
    public nonisolated static func displayName(for member: TeamMember, names: [String: String] = [:]) -> String {
        let direct = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return member.displayName }
        if let uid = member.userId {
            if let hit = names[uid] ?? names["8:orgid:\(uid)"] {
                let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return hit }
            }
        }
        if let mail = member.email {
            let trimmed = mail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return mail }
        }
        return member.id
    }

    /// Owner rows first (each group sorted by display name),
    /// so the roster reads owners → members. Pure helper.
    public nonisolated static func sorted(_ members: [TeamMember], names: [String: String] = [:]) -> [TeamMember] {
        members.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            return displayName(for: $0, names: names)
                .localizedCaseInsensitiveCompare(displayName(for: $1, names: names)) == .orderedAscending
        }
    }

    /// Owner entries of a roster. Pure helper.
    public nonisolated static func owners(of members: [TeamMember]) -> [TeamMember] {
        members.filter(\.isOwner)
    }

    /// Non-owner entries of a roster. Pure helper.
    public nonisolated static func nonOwners(of members: [TeamMember]) -> [TeamMember] {
        members.filter { !$0.isOwner }
    }

    /// Fetch the roster.
    public func load() async {
        state = .loading
        let fetcher = listFetcher
        let teamID = teamID
        do {
            let response = try await Task.detached {
                try fetcher(teamID)
            }.value
            members = response.members
            state = response.members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry).
    public func refresh() {
        Task { await load() }
    }

    /// Add one user (id or UPN), optionally as owner. On success the
    /// returned membership is appended and the state flips to
    /// `.loaded`; failure surfaces as `.error`.
    public func add(user: String, owner: Bool) async {
        let fetcher = addFetcher
        let teamID = teamID
        do {
            let response = try await Task.detached {
                try fetcher(teamID, user, owner)
            }.value
            members.append(response.member)
            state = .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Remove one membership id. On success the row is dropped
    /// locally (empty roster flips to `.empty`); failure surfaces
    /// as `.error` and keeps the row.
    public func remove(memberID: String) async {
        let fetcher = removeFetcher
        let teamID = teamID
        do {
            let response = try await Task.detached {
                try fetcher(teamID, memberID)
            }.value
            members.removeAll { $0.id == response.memberId }
            state = members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Adopt rows without core (tests, previews, demo).
    public func adopt(_ members: [TeamMember]) {
        self.members = members
        state = members.isEmpty ? .empty : .loaded
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// One team's roster: owners + members with add/remove.
///
/// Tapping nothing opens anything — this view manages membership,
/// it never routes to conversations. The host presents it per team
/// (sheet or detail); add/remove need owner rights.
public struct TeamRosterView: View {
    @ObservedObject private var model: TeamRosterViewModel
    @State private var searchText = ""
    @State private var newUser = ""
    @State private var newOwner = false
    @State private var working = false

    public init(model: TeamRosterViewModel) {
        self.model = model
    }

    /// Rows matching `query` (display name, email, or id,
    /// case-insensitive); empty query matches all. Pure helper.
    public static func filtered(_ members: [TeamMember], query: String, names: [String: String] = [:]) -> [TeamMember] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { m in
            TeamRosterViewModel.displayName(for: m, names: names).lowercased().contains(q)
                || (m.email ?? "").lowercased().contains(q)
                || m.id.lowercased().contains(q)
        }
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading members…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "person.3",
                    title: "No members",
                    message: "Nobody on this roster yet.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load members",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedList
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.state)
    }

    private var loadedList: some View {
        let rows = TeamRosterViewModel.sorted(
            Self.filtered(model.members, query: searchText, names: model.names),
            names: model.names)
        let owners = TeamRosterViewModel.owners(of: rows)
        let rest = TeamRosterViewModel.nonOwners(of: rows)
        return VStack(spacing: 0) {
            DietSearchField("Filter members", text: $searchText)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            List {
                if !owners.isEmpty {
                    Section("Owners (\(owners.count))") {
                        ForEach(owners) { member in
                            RosterRow(member: member, names: model.names) {
                                Task { await model.remove(memberID: member.id) }
                            }
                        }
                    }
                }
                Section("Members (\(rest.count))") {
                    if rest.isEmpty {
                        Text("No members")
                            .font(DietType.callout)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    } else {
                        ForEach(rest) { member in
                            RosterRow(member: member, names: model.names) {
                                Task { await model.remove(memberID: member.id) }
                            }
                        }
                    }
                }
                Section("Add") {
                    HStack(spacing: DietSpace.sm) {
                        TextField("User id or email", text: $newUser)
                            .textFieldStyle(.roundedBorder)
                            .disabled(working)
                        Toggle("Owner", isOn: $newOwner)
                            .toggleStyle(.checkbox)
                            .disabled(working)
                        Button(working ? "Adding…" : "Add") {
                            let user = newUser.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !user.isEmpty, !working else { return }
                            working = true
                            let asOwner = newOwner
                            Task {
                                await model.add(user: user, owner: asOwner)
                                newUser = ""
                                newOwner = false
                                working = false
                            }
                        }
                        .disabled(newUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                    .padding(.vertical, DietSpace.xs)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// One roster row: avatar + display name + role/email subtitle.
/// Remove lives in the context menu (destructive, needs owner).
struct RosterRow: View {
    let member: TeamMember
    let names: [String: String]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            DietAvatar(TeamRosterViewModel.displayName(for: member, names: names), size: DietSize.avatarSM)
            VStack(alignment: .leading, spacing: 2) {
                Text(TeamRosterViewModel.displayName(for: member, names: names))
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DietType.callout)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.vertical, DietSpace.xs)
        .contextMenu {
            Button("Remove from team", role: .destructive, action: onRemove)
        }
    }

    private var subtitle: String {
        let role = member.isOwner ? "Owner" : "Member"
        if let mail = member.email, !mail.isEmpty {
            return "\(role) · \(mail)"
        }
        return role
    }
}
