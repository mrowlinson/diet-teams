// TeamCreateSheet.swift — om-jf-teamcreate: new-team sheet (name + description).
import DietDesign
import OstMacCore
import SwiftUI

/// New-team sheet phase: form, in-flight poll, landed, or failed.
/// Pure value type so tests pin the transitions.
public enum TeamCreatePhase: Equatable, Sendable {
    case editing
    case creating
    case created(String)
    case failed(String)

    public var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    public var isCreating: Bool {
        if case .creating = self { return true }
        return false
    }

    /// Created team name, if any.
    public var createdName: String? {
        if case .created(let name) = self { return name }
        return nil
    }

    /// Failure message, if any.
    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// New-team sheet. The host owns presentation and dismisses via
/// `onDone` (Done/Cancel buttons). Create runs the async Graph POST +
/// poll (up to ~120s); the sheet steps through creating/created/failed
/// instead of closing early. Create is armed only for a non-blank name.
public struct TeamCreateSheet: View {
    @ObservedObject private var model: TeamsViewModel
    @State private var name = ""
    @State private var description = ""
    @State private var phase: TeamCreatePhase = .editing
    private let onDone: () -> Void

    public init(model: TeamsViewModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    /// Create gate: non-blank names only. Pure helper so tests pin it.
    public static func canCreate(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("New team")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
            switch phase {
            case .editing, .creating, .failed:
                formBody
            case .created(let teamName):
                createdBody(teamName: teamName)
            }
        }
        .padding(DietSpace.md)
        .frame(minWidth: 320, idealWidth: 400)
    }

    private var formBody: some View {
        Group {
            TextField("Team name", text: $name)
                .textFieldStyle(.plain)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(DietSpace.sm)
                .background(DietColor.wellColor)
                .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                .disabled(phase.isCreating)
            TextField("Description (optional)", text: $description)
                .textFieldStyle(.plain)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(DietSpace.sm)
                .background(DietColor.wellColor)
                .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                .disabled(phase.isCreating)
            if phase.isCreating {
                HStack(spacing: DietSpace.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating team… this can take a minute.")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            if let message = phase.failureMessage {
                Text(message)
                    .font(DietType.callout)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase.isCreating)
                Button(phase.failureMessage == nil ? "Create" : "Retry") {
                    runCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canCreate(name: name) || phase.isCreating)
            }
        }
    }

    private func createdBody(teamName: String) -> some View {
        Group {
            HStack(spacing: DietSpace.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: DietColor.success))
                Text("Created “\(teamName)”")
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
            }
            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runCreate() {
        phase = .creating
        Task {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            await model.createTeam(
                name: trimmed,
                description: description.isEmpty ? nil : description)
            if model.teamCreateError == nil {
                phase = .created(trimmed)
            } else {
                phase = .failed(model.teamCreateError ?? "Couldn't create the team.")
            }
        }
    }
}
