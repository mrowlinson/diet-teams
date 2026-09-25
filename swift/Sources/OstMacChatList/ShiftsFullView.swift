// ShiftsFullView.swift — R10 shifts-fullwidth: the shifts module takes
// the whole window outside the app rail (replaces the squeezed
// chat-list-column hosting + blank chat viewport).
import DietDesign
import OstMacCore
import SwiftUI

/// Full-window Shifts: header row (the same `DietHeaderBar` seam as
/// the conversation/activity detail, so the title row aligns with the
/// rest of the app) + the `ShiftsBrowser` week grid stretched across
/// the freed width. Same store the sidebar tab used — the grid shows
/// already-loaded content with no refetch and no spinner, and flips
/// back leave `openChatID` untouched (zero visible refresh).
public struct ShiftsFullView: View {
    @ObservedObject private var shifts: ShiftsStore

    public init(shifts: ShiftsStore) {
        self.shifts = shifts
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietHeaderBar {
                HStack(spacing: DietSpace.sm) {
                    Text("Shifts")
                        .font(DietType.title3)
                        .foregroundStyle(DietColor.textPrimaryColor)
                    Spacer()
                }
            }
            ShiftsBrowser(model: shifts)
        }
    }
}
