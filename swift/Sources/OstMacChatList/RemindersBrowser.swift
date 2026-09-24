// RemindersBrowser.swift — SwiftUI browser: To Do lists + tasks.
import DietDesign
import OstMacCore
import SwiftUI

/// Reminders browser. Lists picker on top, tasks below with an add field;
/// tapping a circle marks the task done (one-way; completed rows stay
/// visible unless hidden). Mirrors TeamsBrowser states.
///
/// om-reskin-teams: DietDesign states + rows (browser-adjacent to the
/// Teams tab in the same switcher). Errors are `DietEmptyState` /
/// `DietBanner`; dividers are the single `DietSeamH` language.
public struct RemindersBrowser: View {
    @ObservedObject private var model: RemindersViewModel
    @State private var newTitle = ""
    @State private var hideDone = false
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: RemindersViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading reminders…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "checklist",
                    title: "No lists",
                    message: "Your Microsoft To Do lists will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load reminders",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedBody
                    .transition(.opacity)
            }
        }
        // System-default crossfade between content states (same language
        // as the Chats/Teams sections; instant under Reduce Motion).
        // Standard SwiftUI only.
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: model.state)
    }

    private var loadedBody: some View {
        VStack(spacing: 0) {
            Picker("List", selection: Binding(
                get: { model.selectedListID ?? "" },
                set: { model.select(listID: $0) }
            )) {
                ForEach(model.lists) { list in
                    Text(list.name).tag(list.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            DietSeamH()
            if model.tasksLoading, model.tasks.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                let visible = RemindersViewModel.visible(model.tasks, hideDone: hideDone)
                if visible.isEmpty {
                    DietEmptyState(
                        systemImage: "checkmark.circle",
                        title: model.tasks.isEmpty ? "No tasks" : "All done",
                        message: model.tasks.isEmpty
                            ? "Tasks in this list will appear here."
                            : "Completed tasks are hidden.")
                } else {
                    List {
                        ForEach(visible) { task in
                            TaskRow(task: task) {
                                model.complete(taskID: task.id)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            if let err = model.tasksError {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.sm)
                    .padding(.vertical, DietSpace.xs)
            }
            DietSeamH()
            HStack(spacing: DietSpace.sm) {
                TextField("New task", text: $newTitle, onCommit: submit)
                    .textFieldStyle(.plain)
                    .font(DietType.body)
                    .padding(.horizontal, DietSpace.sm)
                    .frame(minHeight: DietSize.controlHeight)
                    .background(DietColor.wellColor)
                    .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: DietRadius.control)
                            .stroke(DietColor.dividerColor, lineWidth: 1))
                Button("Add", action: submit)
                    .buttonStyle(.dietSecondary)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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

    private func submit() {
        model.add(title: newTitle)
        newTitle = ""
    }
}

struct TaskRow: View {
    let task: ReminderTask
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            Button(action: onComplete) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DietSize.iconLG))
                    .foregroundStyle(
                        task.completed
                            ? Color(nsColor: DietColor.success)
                            : DietColor.textSecondaryColor)
            }
            .buttonStyle(.plain)
            .disabled(task.completed)
            .accessibilityLabel(
                A11yLabels.reminderComplete(
                    title: task.title, completed: task.completed))
            .plainFocusRing(radius: 14)
            .help(task.completed ? "Completed" : "Mark done")
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                Text(task.title)
                    .font(DietType.body)
                    .strikethrough(task.completed)
                    .foregroundStyle(
                        task.completed
                            ? DietColor.textSecondaryColor
                            : DietColor.textPrimaryColor)
                    .lineLimit(2)
                if let due = task.displayDue {
                    Text("due \(due)")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            Spacer()
            if task.importance.lowercased() == "high", !task.completed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .accessibilityLabel("High importance")
                    .help("High importance")
            }
        }
        .padding(.vertical, DietSpace.xs)
    }
}
