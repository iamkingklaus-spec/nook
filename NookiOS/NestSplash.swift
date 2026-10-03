import SwiftUI
import UIKit

/// Native template glyphs. Kept in the original file so project membership is
/// unchanged; the former animated twig assembly and disk raster scan are gone.
@MainActor
enum TabGlyph {
    static func symbol(_ name: String) -> UIImage {
        if let cached = symbolCache[name] { return cached }
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = (UIImage(systemName: name, withConfiguration: config) ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
        symbolCache[name] = image
        return image
    }
    private static var symbolCache: [String: UIImage] = [:]
    // Compatibility name used by the existing tab navigation.
    static let nest = symbol("square.stack.3d.up")
}
