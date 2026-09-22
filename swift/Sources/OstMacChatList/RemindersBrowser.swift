// RemindersBrowser.swift — SwiftUI browser: To Do lists + tasks.
import OstMacCore
import SwiftUI

/// Reminders browser. Lists picker on top, tasks below with an add field;
/// tapping a circle marks the task done (one-way; completed rows stay
/// visible unless hidden). Mirrors TeamsBrowser states.
public struct RemindersBrowser: View {
    @ObservedObject private var model: RemindersViewModel
    @State private var newTitle = ""
    @State private var hideDone = false

    public init(model: RemindersViewModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading reminders…").font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No lists").font(.headline)
                    Text("Your Microsoft To Do lists will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Couldn't load reminders").font(.headline)
                    Text(message).font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") { model.refresh() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            case .loaded:
                loadedBody
            }
        }
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refreshTasks() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh tasks")
                .disabled(model.state == .loading || model.tasksLoading)
            }
        }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if model.tasksLoading, model.tasks.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                let visible = RemindersViewModel.visible(model.tasks, hideDone: hideDone)
                if visible.isEmpty {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.tasks.isEmpty ? "No tasks" : "All done")
                        .font(.headline)
                        .padding(.top, 4)
                    Spacer()
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
                Text(err).font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("New task", text: $newTitle, onCommit: submit)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: submit)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Toggle("Hide completed", isOn: $hideDone)
                .font(.caption)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
        HStack(spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.completed ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(task.completed)
            .help(task.completed ? "Completed" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)
                    .lineLimit(2)
                if let due = task.displayDue {
                    Text("due \(due)").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if task.importance.lowercased() == "high", !task.completed {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("High importance")
            }
        }
        .padding(.vertical, 2)
    }
}
