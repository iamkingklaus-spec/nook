import Foundation
import SwiftUI

/// Device-local display preference. Applied to the existing scene, never to its identity.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let storageKey = "appAppearance"
    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(storedValue: defaults.string(forKey: storageKey))
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public static var settingsTitle: String {
        String(localized: "Appearance", bundle: .module)
    }
    public var label: String {
        switch self {
        case .system: String(localized: "Follow System", bundle: .module)
        case .light: String(localized: "Light Appearance", bundle: .module)
        case .dark: String(localized: "Dark Appearance", bundle: .module)
        }
    }
}
