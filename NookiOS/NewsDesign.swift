import SwiftUI

/// Home and navigation colors. Hex values belong only in this semantic palette.
enum NewsPalette {
    static let backgroundPrimary = adaptive(0xF8F6F0, 0x12171D)
    static let backgroundSecondary = adaptive(0xF1EEE7, 0x1A2027)
    static let textPrimary = adaptive(0x101820, 0xF2F0EA)
    static let textSecondary = adaptive(0x66707A, 0xAAB0B7)
    static let textTertiary = adaptive(0x8A9097, 0x808892)
    static let accentPrimary = adaptive(0x203A5F, 0x6689B7)
    static let accentSecondary = adaptive(0x9E3B32, 0xC86A62)
    static let divider = adaptive(0xE1DED5, 0x303943)
    static let borderSubtle = adaptive(0xDDD9D0, 0x29323B)
    static let tabInactive = adaptive(0x737A82, 0x808892)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

enum NewsTypography {
    case greeting, date, hero, horizontalTitle, compactTitle, heroSummary, summary, category, metadata, tabLabel, tabIcon

    var size: CGFloat {
        switch self {
        case .greeting: 16
        case .date: 34
        case .hero: 28
        case .horizontalTitle: 21
        case .compactTitle: 19
        case .heroSummary: 17
        case .summary: 15.5
        case .category: 16.5
        case .metadata: 13
        case .tabLabel: 11
        case .tabIcon: 21
        }
    }

    var style: Font.TextStyle {
        switch self {
        case .date: .largeTitle
        case .hero: .title
        case .horizontalTitle: .title3
        case .compactTitle: .headline
        case .metadata, .tabLabel: .caption
        default: .body
        }
    }

    var design: Font.Design {
        switch self {
        case .date, .hero, .horizontalTitle, .compactTitle: .serif
        default: .default
        }
    }

    var weight: Font.Weight {
        switch self {
        case .hero: .bold
        case .date, .horizontalTitle, .compactTitle, .tabLabel: .semibold
        default: .regular
        }
    }
}

private struct NewsTypeStyle: ViewModifier {
    let role: NewsTypography
    @ScaledMetric private var size: CGFloat

    init(role: NewsTypography) {
        self.role = role
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.style)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: role.weight, design: role.design))
    }
}

extension View {
    func newsFont(_ role: NewsTypography) -> some View { modifier(NewsTypeStyle(role: role)) }
}

struct NewsRule: View {
    var body: some View { Rectangle().fill(NewsPalette.divider).frame(height: 0.5).accessibilityHidden(true) }
}

/// Publication age, never a reading-time estimate. Deliberately has no seconds.
enum NewsMetadataFormat {
    static func age(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return String(localized: "Just now") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        if minutes < 1440 { return String(localized: "\(minutes / 60) hr") }
        let days = minutes / 1440
        return days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
    }
}
