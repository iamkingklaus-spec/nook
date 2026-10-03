import SwiftUI

import NookKit

// Compatibility name for Home; all colors now come from the shared theme.
typealias NewsPalette = NookTheme

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
