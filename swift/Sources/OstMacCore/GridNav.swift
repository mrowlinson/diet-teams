// GridNav.swift — om-a3-keyboard: pure arrow navigation for picker
// grids (ReactionPickerView, KlipyPickerView). No SwiftUI: the views
// keep one `highlight` index and map keys onto (dx, dy) steps.
import Foundation

/// Arrow-key movement over a row-major grid. Horizontal steps stay
/// inside the row (no wrap); vertical steps move by one row, clamped
/// to the last item when the final row is short.
public enum GridNav {
    /// Stepped index, clamped into `0 ..< count` (0 when empty).
    /// `columns` below 1 is treated as a single column.
    public static func move(
        current: Int, dx: Int, dy: Int, columns: Int, count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        let cols = max(columns, 1)
        let start = min(max(current, 0), count - 1)
        let row = start / cols
        let col = start % cols
        let maxRow = (count - 1) / cols
        let newRow = min(max(row + dy, 0), maxRow)
        let newCol = min(max(col + dx, 0), cols - 1)
        return min(newRow * cols + newCol, count - 1)
    }
}
