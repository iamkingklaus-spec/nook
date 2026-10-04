import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shared by the app shell and package-owned screens. Asset catalog mirrors are
/// reserved for UIKit/launch surfaces; SwiftUI reads this single semantic palette.
public enum NookTheme {
    public static let backgroundPrimary = adaptive(0xF7F8FA, 0x171C24)
    public static let backgroundSecondary = adaptive(0xEDF0F4, 0x202733)
    public static let surface = adaptive(0xFCFDFE, 0x242D3A)
    public static let textPrimary = adaptive(0x202A38, 0xEEEDE8)
    public static let textSecondary = adaptive(0x566273, 0xB8C0CB)
    public static let textTertiary = adaptive(0x606C7E, 0x9FAAB9)
    public static let accentPrimary = adaptive(0x365A92, 0xA0BAE3)
    public static let accentSecondary = adaptive(0x9B4350, 0xDBA1A9)
    public static let divider = adaptive(0xDEE2E8, 0x3B4655)
    public static let borderSubtle = adaptive(0xE0E4EA, 0x36404E)
    public static let tabInactive = textSecondary
    public static let success = Color.green
    public static let warning = Color.orange
    public static let error = Color.red
    public static let info = accentPrimary

    public enum Space {
        public static let tight: CGFloat = 6
        public static let inline: CGFloat = 8
        public static let item: CGFloat = 12
        public static let card: CGFloat = 16
        public static let page: CGFloat = 22
        public static let section: CGFloat = 24
    }
    public enum Radius {
        public static let thumbnail: CGFloat = 6
        public static let image: CGFloat = 10
        public static let control: CGFloat = 10
        public static let card: CGFloat = 12
        public static let sheet: CGFloat = 20
    }

    private static func rgb(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

public enum NookTypography {
    public static let display = Font.system(.largeTitle, design: .serif, weight: .semibold)
    public static let title = Font.system(.title, design: .serif, weight: .bold)
    public static let headline = Font.system(.headline, design: .serif, weight: .semibold)
    public static let label = Font.system(.subheadline, weight: .medium)
    public static let toolbar = Font.system(size: 20, weight: .regular)

    public static let pageTitle = display
    public static let articleTitle = title
    public static let sectionTitle = Font.system(.headline, weight: .semibold)
    public static let storyTitle = headline
    public static let body = Font.body
    public static let metadata = Font.subheadline
    public static let caption = Font.caption
    public static let button = Font.system(.subheadline, weight: .semibold)
}

private struct NookScreenStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        #if os(iOS)
        content.scrollContentBackground(.hidden)
            .background(NookTheme.backgroundPrimary.ignoresSafeArea())
            .foregroundStyle(NookTheme.textPrimary).tint(NookTheme.accentPrimary)
            .toolbarBackground(reduceTransparency ? AnyShapeStyle(NookTheme.backgroundPrimary) : AnyShapeStyle(.regularMaterial), for: .navigationBar)
            .presentationBackground(NookTheme.backgroundPrimary)
            .presentationCornerRadius(NookTheme.Radius.sheet)
        #else
        content.scrollContentBackground(.hidden)
            .background(NookTheme.backgroundPrimary)
            .foregroundStyle(NookTheme.textPrimary).tint(NookTheme.accentPrimary)
        #endif
    }
}

private struct NookSurfaceStyle: ViewModifier {
    var glass: Bool
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if glass && !reduceTransparency {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(NookTheme.surface)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(NookTheme.borderSubtle.opacity(glass ? 0.7 : 1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

public struct NookActionStyle: ButtonStyle {
    public enum Emphasis: Equatable { case primary, secondary, quiet }
    private let emphasis: Emphasis
    @Environment(\.isEnabled) private var enabled
    public init(_ emphasis: Emphasis = .secondary) { self.emphasis = emphasis }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(NookTypography.button)
            .foregroundStyle(emphasis == .primary ? NookTheme.surface : NookTheme.accentPrimary)
            .padding(.horizontal, NookTheme.Space.item).frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                    .fill(emphasis == .primary ? NookTheme.accentPrimary :
                            (emphasis == .secondary ? NookTheme.accentPrimary.opacity(0.09) : .clear))
            }
            .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.72 : 1))
    }
}

/// Content rows retain their layout and only dim while pressed (no spring/scale).
public struct NookContentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct NookToolbarItemStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(NookTypography.toolbar)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }
}

private struct NookChromeStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            Group {
                if reduceTransparency { NookTheme.backgroundPrimary }
                else { Rectangle().fill(.regularMaterial) }
            }.ignoresSafeArea(edges: .bottom)
        }
    }
}

public extension View {
    func nookToolbarItem() -> some View { modifier(NookToolbarItemStyle()) }
    func nookChrome() -> some View { modifier(NookChromeStyle()) }

    func nookScreen() -> some View { modifier(NookScreenStyle()) }
    func nookCard() -> some View { modifier(NookSurfaceStyle(glass: false, radius: NookTheme.Radius.card)) }
    func nookGlass(radius: CGFloat = NookTheme.Radius.card) -> some View {
        modifier(NookSurfaceStyle(glass: true, radius: radius))
    }
    func nookRows() -> some View {
        listRowBackground(NookTheme.surface).listRowSeparatorTint(NookTheme.divider)
    }
}
