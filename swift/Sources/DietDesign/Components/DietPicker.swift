// DietPicker.swift — segmented pickers + option rows.
import SwiftUI

/// Segmented picker over any CaseIterable RawRepresentable enum
/// with String raw values. Labels come from the case names —
/// callers pass the type, never raw strings per segment.
public struct DietSegmentedPicker<Value>: View
where Value: Hashable & CaseIterable & RawRepresentable,
    Value.RawValue == String, Value.AllCases: RandomAccessCollection
{
    private let label: String
    @Binding private var selection: Value

    public init(_ label: String, selection: Binding<Value>) {
        self.label = label
        _selection = selection
    }

    public var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(label)
    }
}

/// Single option row (settings-style): symbol + title + subtitle +
/// trailing control. Hover wash, 8pt rhythm.
public struct DietOptionRow<Trailing: View>: View {
    private let systemImage: String
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing
    @State private var hovering = false

    public init(
        systemImage: String, title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textSecondaryColor)
                .frame(width: DietSize.iconLG)
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                Text(title)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                if let subtitle {
                    Text(subtitle)
                        .font(DietType.caption1)
                        .foregroundStyle(
                            DietColor.textSecondaryColor)
                }
            }
            Spacer(minLength: DietSpace.sm)
            trailing
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.xs)
        .background(
            hovering ? DietColor.wellColor : .clear,
            in: RoundedRectangle(
                cornerRadius: DietRadius.control))
        .onHover { hovering = $0 }
    }
}
