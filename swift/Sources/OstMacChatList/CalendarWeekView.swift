// CalendarWeekView.swift — B1 calendar lane: week grid + schedule sheet
// above the existing join list. Extends MeetingsBrowser (embedded below,
// unchanged behavior); the join box, lobby banner, and upcoming rows stay.
import DietDesign
import OstMacCore
import SwiftUI

/// Calendar week browser: 7-day grid with a selected-day list and a
/// schedule sheet, then the join list. The host triggers
/// `week.load()` / `meetings.refresh()` (the embedded browser never
/// self-loads, matching MeetingsBrowser convention).
public struct CalendarWeekBrowser: View {
    @ObservedObject private var week: CalendarWeekStore
    private var meetings: MeetingsViewModel
    @State private var pendingCancelID: String?
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(week: CalendarWeekStore, meetings: MeetingsViewModel) {
        self.week = week
        self.meetings = meetings
    }

    public var body: some View {
        VStack(spacing: 0) {
            weekHeader
            DietSeamH()
            weekSection
            if let err = week.scheduleError {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.vertical, DietSpace.xs)
            }
            if let err = week.cancelError {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.vertical, DietSpace.xs)
            }
            DietSeamH()
            joinHeader
            MeetingsBrowser(model: meetings)
        }
        .sheet(isPresented: $week.showSchedule) {
            ScheduleSheet(store: week)
        }
        .confirmationDialog(
            "Cancel this meeting?", isPresented: cancelConfirmShown,
            titleVisibility: .visible
        ) {
            Button("Cancel meeting", role: .destructive) {
                if let id = pendingCancelID { week.cancel(eventID: id) }
                pendingCancelID = nil
            }
            Button("Keep", role: .cancel) { pendingCancelID = nil }
        }
    }

    private var cancelConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingCancelID != nil },
            set: { if !$0 { pendingCancelID = nil } })
    }

    private var weekHeader: some View {
        HStack(spacing: DietSpace.sm) {
            Button(action: { week.prevWeek() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .help("Previous week")
            .accessibilityLabel("Previous week")
            Text("Week of \(Self.weekLabel(week.weekStart))")
                .font(DietType.callout).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
            Button(action: { week.nextWeek() }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .help("Next week")
            .accessibilityLabel("Next week")
            Spacer()
            Button("Schedule") { week.showSchedule = true }
                .buttonStyle(.borderedProminent)
                .help("Schedule a new meeting")
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.sm)
    }

    private var weekSection: some View {
        Group {
            switch week.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading week…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "calendar",
                    title: "No meetings this week",
                    message: "Meetings in this week will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load week",
                    message: message,
                    actionLabel: "Retry",
                    action: { week.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedWeek
                    .transition(.opacity)
            }
        }
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: week.state)
    }

    private var loadedWeek: some View {
        VStack(spacing: 0) {
            weekGrid
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            selectedDayList
        }
    }

    private var weekGrid: some View {
        let keys = week.dayKeys
        let cols = week.columns
        return HStack(alignment: .top, spacing: DietSpace.xs) {
            ForEach(0 ..< 7, id: \.self) { idx in
                dayColumn(key: keys[idx], meetings: cols[idx])
            }
        }
    }

    private func dayColumn(key: String, meetings: [MeetingItem]) -> some View {
        let selected = week.selectedDayKey == key
            || (week.selectedDayKey == nil && Self.isToday(key))
        return Button {
            week.selectedDayKey = key
        } label: {
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.weekdayLabel(key))
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Text(Self.dayNumber(key))
                        .font(DietType.callout).bold()
                        .foregroundStyle(DietColor.textPrimaryColor)
                }
                ForEach(meetings.prefix(3)) { meeting in
                    eventChip(meeting)
                }
                if meetings.count > 3 {
                    Text("+\(meetings.count - 3) more")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                Spacer(minLength: 0)
            }
            .padding(DietSpace.xs)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .fill(selected
                        ? DietColor.wellColor
                        : Color(nsColor: .controlBackgroundColor).opacity(0.4)))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key), \(meetings.count) meetings")
    }

    private func eventChip(_ meeting: MeetingItem) -> some View {
        HStack(spacing: 2) {
            if meeting.isOnline {
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(meeting.subject)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .lineLimit(1)
                if let time = CalWeek.dayTime(of: meeting) {
                    Text(time)
                        .font(.system(size: 10))
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: DietColor.warning).opacity(0.14)))
        .lineLimit(1)
    }

    private var selectedDayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedDayTitle)
                .font(DietType.callout).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.xs)
            if week.selectedMeetings.isEmpty {
                Text("Nothing scheduled.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.bottom, DietSpace.sm)
            } else {
                List(week.selectedMeetings) { meeting in
                    HStack(spacing: DietSpace.sm) {
                        VStack(alignment: .leading, spacing: DietSpace.xxs) {
                            Text(meeting.subject)
                                .font(DietType.callout).bold()
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .lineLimit(2)
                            HStack(spacing: DietSpace.xs) {
                                if let time = CalWeek.dayTime(of: meeting) {
                                    Text(time)
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor.textSecondaryColor)
                                }
                                if meeting.isOnline {
                                    Text("Teams")
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor.textSecondaryColor)
                                }
                                if let org = meeting.organizer {
                                    Text(org)
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor.textSecondaryColor)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        if week.cancelingID == meeting.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Cancel") { pendingCancelID = meeting.id }
                                .buttonStyle(.bordered)
                                .help("Cancel \(meeting.subject)")
                        }
                    }
                    .padding(.vertical, DietSpace.xxs)
                }
                .listStyle(.plain)
                .frame(minHeight: 90, maxHeight: 220)
            }
        }
    }

    private var selectedDayTitle: String {
        let keys = week.dayKeys
        let key: String
        if let picked = week.selectedDayKey, keys.contains(picked) {
            key = picked
        } else {
            key = keys.first(where: { Self.isToday($0) }) ?? keys.first ?? ""
        }
        return key.isEmpty ? "Selected day" : Self.longDayLabel(key)
    }

    private var joinHeader: some View {
        Text("Upcoming & join")
            .font(DietType.callout).bold()
            .foregroundStyle(DietColor.textPrimaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
    }

    // MARK: - Labels (day keys are "yyyy-MM-dd")

    private static let keyParser: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static func keyDate(_ key: String) -> Date? {
        keyParser.date(from: key)
    }

    private static func weekdayLabel(_ key: String) -> String {
        guard let d = keyDate(key) else { return key }
        let fmt = DateFormatter()
        fmt.dateFormat = "E"
        return fmt.string(from: d)
    }

    private static func dayNumber(_ key: String) -> String {
        guard let d = keyDate(key) else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "d"
        return fmt.string(from: d)
    }

    private static func longDayLabel(_ key: String) -> String {
        guard let d = keyDate(key) else { return key }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE d MMM"
        return fmt.string(from: d)
    }

    private static func weekLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        return fmt.string(from: date)
    }

    private static func isToday(_ key: String) -> Bool {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date()) == key
    }
}

/// Schedule sheet: subject + start/end + Teams toggle. Validation errors
/// surface inline; the sheet closes on success (the store dismisses it).
public struct ScheduleSheet: View {
    @ObservedObject private var store: CalendarWeekStore
    @State private var subject = ""
    @State private var start: Date
    @State private var end: Date
    @State private var online = true

    public init(store: CalendarWeekStore) {
        self.store = store
        let s = Self.defaultStart()
        _start = State(initialValue: s)
        _end = State(initialValue: s.addingTimeInterval(30 * 60))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("Schedule meeting")
                .font(DietType.title3).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
                .font(DietType.callout)
                .accessibilityLabel("Subject")
            DatePicker(
                "Starts", selection: $start,
                displayedComponents: [.date, .hourAndMinute])
                .font(DietType.callout)
                .datePickerStyle(.compact)
            DatePicker(
                "Ends", selection: $end,
                displayedComponents: [.date, .hourAndMinute])
                .font(DietType.callout)
                .datePickerStyle(.compact)
            Toggle("Teams meeting", isOn: $online)
                .font(DietType.callout)
                .toggleStyle(.switch)
                .help("Generate a Teams join link for this meeting")
            if let err = store.scheduleError {
                DietBanner(.error, message: err)
            }
            if store.scheduling {
                HStack(spacing: DietSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text("Scheduling…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { store.dismissSchedule() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.scheduling)
            }
        }
        .padding(DietSpace.edge)
        .frame(width: 360)
    }

    private func submit() {
        let tz = TimeZone.current
        store.schedule(
            subject: subject,
            start: CalWeek.graphDateTime(start, timeZone: tz),
            end: CalWeek.graphDateTime(end, timeZone: tz),
            online: online)
    }

    private static func defaultStart() -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: next)
        return cal.date(from: comps) ?? next
    }
}
