import SwiftUI

/// The desktop app's palette, ported verbatim from apps/desktop/src/renderer/src/styles.css's
/// `:root` custom properties so the two Rockys look like the same character. Names match the CSS
/// variable names (--ink, --mint, --amber, ...) rather than being renamed to SwiftUI conventions,
/// so a change on one side is easy to mirror on the other.
enum RockyTheme {
    static let ink = Color(hex: 0x080B0A)
    static let deep = Color(hex: 0x141A17)
    static let mint = Color(hex: 0x9BB49B)
    static let mintBright = Color(hex: 0xC8D7B5)
    static let teal = Color(hex: 0x607F6B)
    static let rust = Color(hex: 0xB85C36)
    static let amber = Color(hex: 0xD8944F)
    static let amberBright = Color(hex: 0xFFC37D)

    /// `.orb-only`'s layered background: two coloured pools over a near-black diagonal wash.
    static var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x151713), RockyTheme.ink],
                startPoint: UnitPoint(x: 0.33, y: 0),
                endPoint: UnitPoint(x: 0.67, y: 1)
            )
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height)
                RadialGradient(
                    colors: [Color(hex: 0xA96830).opacity(0.20), .clear],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: side * 0.38
                )
                RadialGradient(
                    colors: [Color(hex: 0x45634E).opacity(0.10), .clear],
                    center: UnitPoint(x: 0.18, y: 0.82),
                    startRadius: 0,
                    endRadius: side * 0.32
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// The faint dot grid behind the orb (`.star-field`): 1px dots on a 46px lattice, faded out
/// toward the edges by a radial mask, exactly as the CSS does it.
struct StarField: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 46
            let dot = CGSize(width: 2, height: 2)
            for x in stride(from: 0, through: size.width, by: spacing) {
                for y in stride(from: 0, through: size.height, by: spacing) {
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0x8CE4CF)))
                }
            }
        }
        .opacity(0.28)
        .mask {
            RadialGradient(colors: [.black, .clear], center: .center, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
