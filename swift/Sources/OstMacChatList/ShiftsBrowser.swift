// ShiftsBrowser.swift — om-shifts lane: schedule week grid (read-only).
import DietDesign
import OstMacCore
import SwiftUI

/// Shifts browser. Team picker on top, 7-day grid below, time-off
/// strip at the bottom. Display only: no swap or time-off requests.
/// Mirrors RemindersBrowser states; errors are `DietEmptyState`.
public struct ShiftsBrowser: View {
    @ObservedObject private var model: ShiftsStore
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: ShiftsStore) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading shifts…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "calendar.badge.clock",
                    title: "No shifts this week",
                    message: "Shifts and time off for the selected team will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load shifts",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedBody
                    .transition(.opacity)
            }
        }
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: model.state)
    }

    private var loadedBody: some View {
        VStack(spacing: 0) {
            Picker("Team", selection: Binding(
                get: { model.selectedTeamID ?? "" },
                set: { model.select(teamID: $0) }
            )) {
                ForEach(model.teams) { team in
                    Text(team.name).tag(team.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            DietSeamH()
            ScrollView {
                VStack(alignment: .leading, spacing: DietSpace.sm) {
                    if let week = model.week {
                        weekGrid(week)
                        if !week.timeOff.isEmpty {
                            DietSeamH()
                            timeOffStrip(week)
                        }
                    }
                }
                .padding(DietSpace.sm)
            }
        }
    }

    private var dayColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: DietSpace.xs, alignment: .top),
            count: 7)
    }

    private func weekGrid(_ week: ShiftWeek) -> some View {
        LazyVGrid(columns: dayColumns, spacing: DietSpace.xs) {
            ForEach(0 ..< 7, id: \.self) { day in
                dayCell(week: week, day: day)
            }
        }
    }

    private func dayCell(week: ShiftWeek, day: Int) -> some View {
        let date = Calendar.current.date(
            byAdding: .day, value: day, to: week.weekStart)
        let shifts = day < week.columns.count ? week.columns[day] : []
        return VStack(alignment: .leading, spacing: DietSpace.xs) {
            Text(Self.dayHeader(date: date))
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            if shifts.isEmpty {
                Text("—")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor.opacity(0.5))
            } else {
                ForEach(shifts) { shift in
                    shiftChip(shift)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shiftChip(_ shift: ShiftItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(shift.displayName.isEmpty ? "Shift" : shift.displayName)
                .font(DietType.caption1)
                .lineLimit(2)
            if let range = Self.timeRange(start: shift.start, end: shift.end) {
                Text(range)
                    .font(DietType.caption2)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            }
            if shift.isDraft {
                Text("draft")
                    .font(DietType.caption2)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .italic()
            }
        }
        .padding(DietSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DietColor.wellColor)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
    }

    private func timeOffStrip(_ week: ShiftWeek) -> some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            Text("Time off")
                .font(DietType.callout)
            if !week.balances.isEmpty {
                HStack(spacing: DietSpace.xs) {
                    ForEach(week.balances, id: \.reason.id) { balance in
                        Text("\(balance.reason.name) × \(balance.count)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
            }
            ForEach(week.timeOff) { item in
                HStack {
                    Text(reasonName(for: item, in: week))
                        .font(DietType.caption1)
                    Spacer()
                    Text(Self.dateRange(start: item.start, end: item.end))
                        .font(DietType.caption2)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
        }
    }

    private func reasonName(for item: TimeOffItem, in week: ShiftWeek) -> String {
        if let rid = item.reasonId,
           let match = week.balances.first(where: { $0.reason.id == rid })
        {
            return match.reason.name
        }
        return "Time off"
    }

    // -- Formatting helpers (pure; also used by tests via public API) --

    static func dayHeader(date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dayFormatter.string(from: date)
    }

    static func timeRange(start: String?, end: String?) -> String? {
        guard let s = ShiftItem.parse(dateTime: start) else { return nil }
        let lhs = Self.timeFormatter.string(from: s)
        guard let e = ShiftItem.parse(dateTime: end) else { return lhs }
        return "\(lhs)–\(Self.timeFormatter.string(from: e))"
    }

    static func dateRange(start: String?, end: String?) -> String {
        let lhs = ShiftItem.parse(dateTime: start).map { Self.dayFormatter.string(from: $0) } ?? "?"
        let rhs = ShiftItem.parse(dateTime: end).map { Self.dayFormatter.string(from: $0) } ?? "?"
        return "\(lhs) – \(rhs)"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Ed")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
