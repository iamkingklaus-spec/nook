import SwiftUI

/// Used only for brand/learning surfaces, never inside an article's body.
/// The installed icon remains a full-bleed square; this is its in-app framing.
public struct NookieBrandMark: View {
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    public init(size: CGFloat = 64) { self.size = size }
    public var body: some View {
        Image("NookieCharacter", bundle: .module)
            .resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
            .accessibilityLabel("Nookie")
            .opacity(appeared || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: appeared)
            .onAppear { appeared = true }
    }
}
