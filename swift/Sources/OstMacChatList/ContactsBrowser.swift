// ContactsBrowser.swift — om-f2-contacts lane: contacts section browser.
//
// Directory search + speed dial. Rows show display name + email +
// a live PresenceDot; row taps open the 1:1 chat via the host's
// `onPick` (the shared `openSearchPerson` person11 path — this view
// owns no create-path code). Zero-visible-refresh: rows key on the
// stable hit id, dots fill via the observed PresenceStore without
// reordering, and pin toggles only move section membership.
import DietDesign
import OstMacCore
import SwiftUI

/// Contacts section: search field, speed-dial pins, directory rows.
public struct ContactsBrowser: View {
    @ObservedObject private var model: ContactsStore
    @ObservedObject private var presence: PresenceStore
    private let onPick: (TeamMember) -> Void
    @State private var query = ""
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: ContactsStore, presence: PresenceStore,
        onPick: @escaping (TeamMember) -> Void
    ) {
        self.model = model
        self.presence = presence
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietSearchField("Search contacts", text: $query)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            content
        }
        .onChange(of: query) { newQuery in
            Task { await model.search(query: newQuery) }
        }
        .task {
            // Dots for restored pins (blank query runs no search).
            await model.refreshPresence()
        }
        .animation(
            DietMotion.gated(reduceMotion: reduceMotion),
            value: model.results.count)
    }

    @ViewBuilder
    private var content: some View {
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let pins = model.pinnedContacts()
        if let message = model.error, model.results.isEmpty {
            DietEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't search contacts",
                message: message,
                actionLabel: "Try Again",
                action: { model.retry() })
                .transition(.opacity)
        } else if blank, model.results.isEmpty, pins.isEmpty {
            DietEmptyState(
                systemImage: "person.crop.circle",
                title: "Search your contacts",
                message: "Type a name or email to search the directory.")
                .transition(.opacity)
        } else if !blank, model.results.isEmpty, !model.isSearching {
            pinnedList(pins, rows: [])
                .transition(.opacity)
        } else {
            pinnedList(pins, rows: model.results)
                .transition(.opacity)
        }
    }

    /// Pinned section above results (both lists stable-id; dots fill
    /// async without row jumps).
    private func pinnedList(_ pins: [TeamMember], rows: [TeamMember]) -> some View {
        List {
            if !pins.isEmpty {
                Section("Speed dial (\(pins.count))") {
                    ForEach(pins) { person in
                        ContactRow(
                            person: person,
                            availability: availability(for: person),
                            pinned: true,
                            onPick: { onPick(person) },
                            onTogglePin: { model.unpin(ref: pinRef(of: person)) })
                    }
                }
            }
            let rest = rows.filter { !isPinnedRow($0) }
            Section(pins.isEmpty ? "Contacts" : "Results (\(rest.count))") {
                if rest.isEmpty {
                    Text("No contacts found")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                } else {
                    ForEach(rest) { person in
                        ContactRow(
                            person: person,
                            availability: availability(for: person),
                            pinned: false,
                            onPick: { onPick(person) },
                            onTogglePin: { model.pin(person) })
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Known availability for one hit, or nil for the hollow unknown
    /// dot (unref'd, unresolved, or failed ids — never a spinner).
    private func availability(for person: TeamMember) -> String? {
        guard let ref = ContactsStore.pinID(for: person) else { return nil }
        return presence.peers[ref]?.availability
    }

    /// True when the hit already renders in speed dial (pinned rows
    /// show once — in the pinned section, never duplicated below).
    private func isPinnedRow(_ person: TeamMember) -> Bool {
        model.isPinned(person)
    }

    /// Pin ref for a (possibly degraded) pinned row: the person11 ref
    /// when present, else the fallback id (which IS the ref).
    private func pinRef(of person: TeamMember) -> String {
        ContactsStore.pinID(for: person) ?? person.id
    }
}

/// One contact row: presence dot + avatar + name/email + pin toggle.
/// The whole row opens the 1:1 chat; the star only (un)pins.
struct ContactRow: View {
    let person: TeamMember
    let availability: String?
    let pinned: Bool
    let onPick: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: DietSpace.sm) {
                PresenceDot(availability: availability)
                DietAvatar(displayName, size: DietSize.avatarSM)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(DietType.body)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    if let email = person.email, !email.isEmpty {
                        Text(email)
                            .font(DietType.callout)
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: DietSize.iconMD))
                        .foregroundStyle(
                            pinned ? Color.accentColor
                                : DietColor.textTertiaryColor)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Remove from speed dial" : "Add to speed dial")
                .accessibilityIdentifier(
                    "contact-pin-\(person.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .padding(.vertical, DietSpace.xs)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contact-row-\(person.id)")
    }

    private var displayName: String {
        let direct = person.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !direct.isEmpty { return person.displayName }
        if let mail = person.email, !mail.isEmpty { return mail }
        return person.id
    }
}
