// ChannelCreateSheet.swift — om-h3-create: new-channel sheet (team + name + description).
import DietDesign
import OstMacCore
import SwiftUI

/// New-channel sheet. The host owns presentation and dismisses via
/// `onDone` once the create lands (failures stay open with the model
/// error inline). Create is armed only for a non-blank name.
public struct ChannelCreateSheet: View {
    @ObservedObject private var model: TeamsViewModel
    @State private var teamID: String
    @State private var name = ""
    @State private var description = ""
    @State private var creating = false
    private let onDone: () -> Void

    public init(
        model: TeamsViewModel, initialTeamID: String? = nil,
        onDone: @escaping () -> Void
    ) {
        self.model = model
        _teamID = State(initialValue: initialTeamID ?? model.teams.first?.teamId ?? "")
        self.onDone = onDone
    }

    /// Create gate: non-blank names only. Pure helper so tests pin it.
    public static func canCreate(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("New channel")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
            Picker("Team", selection: $teamID) {
                ForEach(model.teams) { team in
                    Text(team.name).tag(team.teamId)
                }
            }
            .pickerStyle(.menu)
            TextField("Channel name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(DietType.body)
            TextField("Description (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
                .font(DietType.body)
            if let error = model.createError {
                Text(error)
                    .font(DietType.callout)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    creating = true
                    Task {
                        await model.createChannel(
                            teamID: teamID, name: name,
                            description: description.isEmpty ? nil : description)
                        creating = false
                        if model.createError == nil { onDone() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canCreate(name: name) || teamID.isEmpty || creating)
            }
        }
        .padding(DietSpace.md)
        .frame(minWidth: 320, idealWidth: 400)
    }
}
