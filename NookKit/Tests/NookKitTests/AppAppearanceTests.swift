import Foundation
import SwiftUI
import Testing
import NookKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("Appearance and editorial palette")
@MainActor
struct AppAppearanceTests {
    @Test func missingPreferenceFollowsSystem() {
        #expect(AppAppearance(storedValue: nil) == .system)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    @Test func unknownPreferenceFallsBackSafely() {
        #expect(AppAppearance(storedValue: "old-sepia-theme") == .system)
        #expect(AppAppearance(storedValue: "") == .system)
    }

    @Test func explicitModesOverrideSystem() {
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test func exactlyThreeStableSettingsChoices() {
        #expect(AppAppearance.allCases.map(\.id) == ["system", "light", "dark"])
        #expect(AppAppearance.allCases.allSatisfy { !$0.label.isEmpty })
    }

    @Test func persistedChoiceSurvivesReload() throws {
        let name = "Nook.AppearanceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for choice in AppAppearance.allCases {
            defaults.set(choice.rawValue, forKey: AppAppearance.storageKey)
            let reopened = try #require(UserDefaults(suiteName: name))
            #expect(AppAppearance.load(from: reopened) == choice)
        }
    }

    @Test func removedPreferenceRestoresSystem() throws {
        let name = "Nook.AppearanceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: AppAppearance.storageKey)
        #expect(AppAppearance.load(from: defaults) == .dark)
        defaults.removeObject(forKey: AppAppearance.storageKey)
        #expect(AppAppearance.load(from: defaults) == .system)
    }

    @Test func readingTextAndLinksMeetContrastInBothAppearances() {
        for dark in [false, true] {
            for background in [NookTheme.backgroundPrimary, NookTheme.backgroundSecondary, NookTheme.surface] {
                for foreground in [NookTheme.textPrimary, NookTheme.textSecondary, NookTheme.textTertiary, NookTheme.accentPrimary] {
                    let a = luminance(foreground, dark: dark)
                    let b = luminance(background, dark: dark)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }

    @Test func darkSurfacesHaveSeparationWithoutPureBlack() {
        let canvas = luminance(NookTheme.backgroundPrimary, dark: true)
        let surface = luminance(NookTheme.surface, dark: true)
        #expect(canvas > 0)
        #expect(surface > canvas)
        #expect(luminance(NookTheme.textPrimary, dark: true) < 1)
    }

    private func luminance(_ color: Color, dark: Bool) -> Double {
        var components: [Double] = []
        #if canImport(UIKit)
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        components = [Double(r), Double(g), Double(b)]
        #else
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            components = [Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent)]
        }
        #endif
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
