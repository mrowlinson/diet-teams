// ShowcaseApp.swift — DietShowcase: renders EVERY DietDesign
// component in one window (cohesion proof). Dogfoods DietColumns.
// Usage: DietShowcase [--dark | --light] [--section <prefix>]
import DietDesign
import SwiftUI

enum ShowcaseSection: String, CaseIterable {
    case tokens = "Tokens"
    case buttons = "Buttons"
    case pickers = "Pickers"
    case cards = "Cards"
    case avatars = "Avatars"
    case bubbles = "Bubbles"
    case fields = "Fields"
    case states = "Empty + Banners"
    case sheet = "Sheet"

    var systemImage: String {
        switch self {
        case .tokens: return "swatchpalette"
        case .buttons: return "button.horizontal.top.press"
        case .pickers: return "slider.horizontal.3"
        case .cards: return "rectangle.stack"
        case .avatars: return "person.crop.circle"
        case .bubbles: return "bubble.left.and.bubble.right"
        case .fields: return "text.cursor"
        case .states: return "exclamationmark.bubble"
        case .sheet: return "macwindow"
        }
    }
}

enum DemoFilter: String, CaseIterable {
    case chats = "Chats"
    case teams = "Teams"
    case reminders = "Reminders"
}

struct ShowcaseRoot: View {
    @State private var section: ShowcaseSection = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"),
            i + 1 < args.count,
            let match = ShowcaseSection.allCases.first(where: {
                $0.rawValue.lowercased().hasPrefix(
                    args[i + 1].lowercased())
            })
        {
            return match
        }
        return .tokens
    }()
    @State private var filter: DemoFilter = .chats
    @State private var query = ""
    @State private var draft = ""
    @State private var toggleOn = true
    @State private var sent: [String] = []
    @State private var showSheet = false
    @State private var bannerVisible = true

    var body: some View {
        DietColumns(title: "DietShowcase") {
            sidebar
        } content: {
            VStack(spacing: 0) {
                DietHeaderBar {
                    HStack {
                        Text(section.rawValue).font(DietType.title2)
                        Spacer()
                        DietIconButton(
                            "Toggle appearance",
                            systemImage: "circle.lefthalf.filled"
                        ) {
                            ShowcaseAppearance.shared.toggle()
                        }
                    }
                }
                ScrollView {
                    sectionBody
                        .padding(DietSpace.md)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(ShowcaseSection.allCases, id: \.self) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .tokens: tokensSection
        case .buttons: buttonsSection
        case .pickers: pickersSection
        case .cards: cardsSection
        case .avatars: avatarsSection
        case .bubbles: bubblesSection
        case .fields: fieldsSection
        case .states: statesSection
        case .sheet: sheetSection
        }
    }

    // MARK: - Tokens

    private var tokensSection: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            DietSectionCard("Type scale", systemImage: "textformat") {
                VStack(alignment: .leading, spacing: DietSpace.row) {
                    ForEach(DietType.scale, id: \.name) { row in
                        HStack {
                            Text(row.name)
                                .font(DietType.captionMono)
                                .foregroundStyle(
                                    DietColor.textTertiaryColor)
                                .frame(width: 88, alignment: .leading)
                            Text("Agile teams ship green builds")
                                .font(row.font)
                        }
                    }
                }
            }
            DietSectionCard(
                "Spacing grid", systemImage: "ruler"
            ) {
                VStack(alignment: .leading, spacing: DietSpace.row) {
                    ForEach(
                        [
                            ("xxs", DietSpace.xxs), ("xs", DietSpace.xs),
                            ("sm", DietSpace.sm), ("md", DietSpace.md),
                            ("lg", DietSpace.lg), ("xl", DietSpace.xl),
                            ("xxl", DietSpace.xxl),
                        ], id: \.0
                    ) { name, value in
                        HStack {
                            Text(name)
                                .font(DietType.captionMono)
                                .frame(width: 40, alignment: .leading)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: value, height: 8)
                            Text("\(Int(value))pt")
                                .font(DietType.captionMono)
                                .foregroundStyle(
                                    DietColor.textSecondaryColor)
                        }
                    }
                }
            }
            DietSectionCard("Surfaces", systemImage: "square.stack") {
                LazyVGrid(
                    columns: [.init(.adaptive(minimum: 120))],
                    spacing: DietSpace.sm
                ) {
                    swatch("window", DietColor.windowColor)
                    swatch("sidebar", DietColor.sidebarColor)
                    swatch("card", DietColor.cardColor)
                    swatch("well", DietColor.wellColor)
                    swatch(
                        "bubbleOut", DietColor.bubbleOutColor)
                    swatch("bubbleIn", DietColor.bubbleInColor)
                }
            }
            DietSectionCard(
                "Divider language", systemImage: "minus"
            ) {
                VStack(alignment: .leading, spacing: DietSpace.sm) {
                    Text("1px · DietColor.divider · everywhere")
                        .font(DietType.caption1)
                        .foregroundStyle(
                            DietColor.textSecondaryColor)
                    DietDividerH()
                    HStack {
                        Text("columns").font(DietType.caption1)
                        DietDividerV().frame(height: 16)
                        Text("share").font(DietType.caption1)
                        DietDividerV().frame(height: 16)
                        Text("one seam").font(DietType.caption1)
                    }
                    DietDividerH()
                }
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: DietSpace.xs) {
            RoundedRectangle(cornerRadius: DietRadius.control)
                .fill(color)
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(
                        cornerRadius: DietRadius.control
                    ).stroke(DietColor.dividerColor, lineWidth: 1))
            Text(name).font(DietType.captionMono)
        }
    }

    // MARK: - Buttons

    private var buttonsSection: some View {
        DietSectionCard("Buttons", systemImage: "button.horizontal.top.press") {
            VStack(alignment: .leading, spacing: DietSpace.sm) {
                HStack(spacing: DietSpace.sm) {
                    Button("Primary") {}.buttonStyle(.dietPrimary)
                    Button("Secondary") {}
                        .buttonStyle(.dietSecondary)
                    Button("Delete") {}
                        .buttonStyle(.dietDestructive)
                }
                HStack(spacing: DietSpace.xs) {
                    DietIconButton(
                        "Refresh", systemImage: "arrow.clockwise") {}
                    DietIconButton(
                        "Search", systemImage: "magnifyingglass") {}
                    DietIconButton(
                        "Call", systemImage: "phone") {}
                    DietIconButton(
                        "Video", systemImage: "video") {}
                }
                Text("hover + focus + keyboard states on all controls")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textTertiaryColor)
            }
        }
    }

    // MARK: - Pickers

    private var pickersSection: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            DietSectionCard("Segmented", systemImage: "slider.horizontal.3") {
                DietSegmentedPicker("Filter", selection: $filter)
                    .frame(maxWidth: 400)
            }
            DietSectionCard("Option rows", systemImage: "list.bullet") {
                VStack(spacing: DietSpace.xs) {
                    DietOptionRow(
                        systemImage: "bell",
                        title: "Notifications",
                        subtitle: "Mentions and replies"
                    ) {
                        Toggle(
                            "Notifications", isOn: $toggleOn
                        ).labelsHidden()
                    }
                    DietDividerH()
                    DietOptionRow(
                        systemImage: "moon",
                        title: "Do not disturb",
                        subtitle: "Pause all banners"
                    ) {
                        Toggle(
                            "Do not disturb",
                            isOn: .constant(false)
                        ).labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            DietSectionCard("Section card", systemImage: "rectangle.stack") {
                Text("Title row + seam + 16pt body. Sections stack on the 8pt grid.")
                    .font(DietType.body)
            }
            DietCard {
                Text("Plain card: 12pt radius, 1px divider-color border.")
                    .font(DietType.body)
            }
        }
    }

    // MARK: - Avatars

    private var avatarsSection: some View {
        DietSectionCard("Avatars + presence", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: DietSpace.sm) {
                HStack(spacing: DietSpace.sm) {
                    DietAvatar(
                        "Priya Nair", presence: .available,
                        size: DietSize.avatarLG)
                    DietAvatar(
                        "Tom Becker", presence: .busy,
                        size: DietSize.avatarMD)
                    DietAvatar(
                        "Ava Lindqvist", presence: .away,
                        size: DietSize.avatarMD)
                    DietAvatar("Jo", presence: .dnd)
                    DietAvatar("", presence: .offline)
                }
                HStack(spacing: DietSpace.md) {
                    ForEach(DietPresence.allCases, id: \.self) { status in
                        Label {
                            Text(status.label).font(DietType.caption1)
                        } icon: {
                            DietPresenceDot(status)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bubbles

    private var bubblesSection: some View {
        DietSectionCard(
            "Message bubbles",
            systemImage: "bubble.left.and.bubble.right"
        ) {
            VStack(alignment: .leading, spacing: DietSpace.sm) {
                DietDaySeparator("Today")
                DietBubble(
                    "Build is green, packaging the demo now.",
                    direction: .incoming)
                DietBubble(
                    "Ship it. I'll take screenshots for the review.",
                    direction: .outgoing)
                DietBubble(
                    "This send failed (airplane mode?)",
                    direction: .outgoing, failed: true) {}
            }
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        DietSectionCard("Fields", systemImage: "text.cursor") {
            VStack(alignment: .leading, spacing: DietSpace.sm) {
                DietSearchField("Filter chats", text: $query)
                    .frame(maxWidth: 400)
                DietComposer("Message", text: $draft) {
                    sent.append(draft)
                    draft = ""
                }
                if !sent.isEmpty {
                    Text("\(sent.count) sent (local echo)")
                        .font(DietType.caption1)
                        .foregroundStyle(
                            DietColor.textSecondaryColor)
                }
            }
        }
    }

    // MARK: - States

    private var statesSection: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            DietSectionCard("Banners", systemImage: "exclamationmark.bubble") {
                VStack(spacing: DietSpace.sm) {
                    if bannerVisible {
                        DietBanner(
                            .info,
                            message: "Syncing 3 chats in the background.") {
                                bannerVisible = false
                            }
                    }
                    DietBanner(
                        .success,
                        message: "All chats are up to date.")
                    DietBanner(
                        .warning,
                        message: "Offline — showing cached chats.")
                    DietBanner(
                        .error,
                        message: "Send failed. Retry when online.")
                }
            }
            DietSectionCard("Empty state", systemImage: "tray") {
                DietEmptyState(
                    systemImage: "tray",
                    title: "No results",
                    message: "Nothing matches this filter yet. Try a shorter query or clear the search.",
                    actionLabel: "Clear search") { query = "" }
                    .frame(height: 280)
            }
        }
    }

    // MARK: - Sheet

    private var sheetSection: some View {
        DietSectionCard("Sheet", systemImage: "macwindow") {
            Button("Open sheet") { showSheet = true }
                .buttonStyle(.dietPrimary)
        }
        .sheet(isPresented: $showSheet) {
            DietSheet("Catch up") {
                VStack(alignment: .leading, spacing: DietSpace.sm) {
                    Text("3 unread threads since 09:00.")
                        .font(DietType.body)
                    Button("Done") { showSheet = false }
                        .buttonStyle(.dietPrimary)
                }
            }
        }
    }
}

final class ShowcaseAppearance: ObservableObject {
    static let shared = ShowcaseAppearance()
    @Published var scheme: ColorScheme?
    private var dark = false

    func toggle() {
        dark.toggle()
        scheme = dark ? .dark : .light
    }

    func seed() {
        if CommandLine.arguments.contains("--dark") {
            dark = true
            scheme = .dark
        } else if CommandLine.arguments.contains("--light") {
            scheme = .light
        }
    }
}

@main
struct DietShowcaseApp: App {
    @StateObject private var appearance = ShowcaseAppearance.shared

    init() {
        ShowcaseAppearance.shared.seed()
    }

    var body: some Scene {
        WindowGroup {
            ShowcaseRoot()
                .preferredColorScheme(appearance.scheme)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}
