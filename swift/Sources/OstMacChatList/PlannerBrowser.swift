// PlannerBrowser.swift — SwiftUI browser: team plans + buckets + tasks.
import DietDesign
import OstMacCore
import SwiftUI

/// Planner browser. Team + plan pickers on top, bucket sections below
/// with task rows; tapping a circle completes (or reopens) the task.
/// Mirrors RemindersBrowser states (DietDesign rows, `DietSeamH`).
public struct PlannerBrowser: View {
    @ObservedObject private var model: PlannerViewModel
    @State private var newTitle = ""
    @State private var addBucketID = ""
    @State private var hideDone = false
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: PlannerViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading planner…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "square.grid.2x2",
                    title: "No teams",
                    message: "Your teams' Planner boards will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load planner",
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
                set: { model.selectTeam(teamID: $0) }
            )) {
                ForEach(model.teams) { team in
                    Text(team.name).tag(team.teamId)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            Picker("Plan", selection: Binding(
                get: { model.selectedPlanID ?? "" },
                set: { model.selectPlan(planID: $0) }
            )) {
                ForEach(model.plans) { plan in
                    Text(plan.title).tag(plan.planId)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DietSpace.sm)
            .padding(.bottom, DietSpace.xs)
            .disabled(model.plans.isEmpty)
            DietSeamH()
            if model.boardLoading, model.tasks.isEmpty, model.buckets.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if model.plans.isEmpty {
                DietEmptyState(
                    systemImage: "square.grid.2x2",
                    title: "No plans",
                    message: "This team has no Planner boards yet.")
            } else {
                boardList
            }
            if let err = model.boardError {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.vertical, DietSpace.xs)
            }
            DietSeamH()
            addRow
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            Toggle("Hide completed", isOn: $hideDone)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DietSpace.sm)
                .padding(.bottom, DietSpace.sm)
        }
    }

    private var boardList: some View {
        List {
            ForEach(model.buckets) { bucket in
                let rows = PlannerViewModel.visible(
                    model.tasks, bucketID: bucket.bucketId, hideDone: hideDone)
                if !rows.isEmpty {
                    Section(header: Text(bucket.name)) {
                        ForEach(rows) { task in
                            PlannerTaskRow(task: task) {
                                if task.completed {
                                    model.reopen(taskID: task.taskId)
                                } else {
                                    model.complete(taskID: task.taskId)
                                }
                            }
                        }
                    }
                }
            }
            let orphans = PlannerViewModel.orphaned(
                model.tasks, buckets: model.buckets)
            if !orphans.isEmpty {
                Section(header: Text("Other")) {
                    ForEach(orphans) { task in
                        PlannerTaskRow(task: task) {
                            if task.completed {
                                model.reopen(taskID: task.taskId)
                            } else {
                                model.complete(taskID: task.taskId)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var addRow: some View {
        HStack(spacing: DietSpace.sm) {
            Picker("Bucket", selection: $addBucketID) {
                ForEach(model.buckets) { bucket in
                    Text(bucket.name).tag(bucket.bucketId)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 120)
            .disabled(model.buckets.isEmpty)
            .onAppear { adoptFirstBucket() }
            .onChange(of: model.buckets) { _ in adoptFirstBucket() }
            TextField("New task", text: $newTitle, onCommit: submit)
                .textFieldStyle(.roundedBorder)
                .font(DietType.body)
            Button("Add", action: submit)
                .buttonStyle(.bordered)
                .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !addBucketID.isEmpty
    }

    private func adoptFirstBucket() {
        if addBucketID.isEmpty
            || !model.buckets.contains(where: { $0.bucketId == addBucketID })
        {
            addBucketID = model.buckets.first?.bucketId ?? ""
        }
    }

    private func submit() {
        guard canSubmit else { return }
        model.add(bucketID: addBucketID, title: newTitle)
        newTitle = ""
    }
}

struct PlannerTaskRow: View {
    let task: PlannerTask
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            Button(action: onToggle) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DietSize.iconLG))
                    .foregroundStyle(
                        task.completed
                            ? Color(nsColor: DietColor.success)
                            : DietColor.textSecondaryColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                task.completed
                    ? "Reopen \(task.title)" : "Complete \(task.title)")
            .plainFocusRing(radius: 14)
            .help(task.completed ? "Reopen" : "Mark done")
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                Text(task.title)
                    .font(DietType.body)
                    .strikethrough(task.completed)
                    .foregroundStyle(
                        task.completed
                            ? DietColor.textSecondaryColor
                            : DietColor.textPrimaryColor)
                    .lineLimit(2)
                if task.percent > 0, !task.completed {
                    Text("\(task.percent)%")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                if let due = task.displayDue {
                    Text("due \(due)")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            Spacer()
        }
        .padding(.vertical, DietSpace.xs)
    }
}
