import SwiftUI

/// What the orb is doing, mirroring desktop's `phase-*` CSS classes one-for-one so both apps
/// express the same states the same way. The iOS app's own connection/voice states map onto
/// these in ContentView.
enum OrbPhase {
    case idle, connecting, listening, speaking, error
}

/// Rocky's stone: the organic blob from `.rock-orb`, ported to SwiftUI.
///
/// CSS gets the shape from `border-radius: 46% 54% 59% 41% / 48% 43% 57% 52%` -- four corners,
/// each with its own horizontal and vertical radius. Because every edge's two radii sum to
/// exactly 100%, there are no straight segments at all: the outline is four elliptical arcs, which
/// is what this traces with the standard 0.5523 circular-Bezier constant.
struct OrbShape: Shape {
    private static let k: CGFloat = 0.5523

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let k = Self.k
        // Corner radii, in the same order CSS lists them (top-left, top-right, bottom-right,
        // bottom-left), horizontal then vertical.
        let tlX = 0.46 * w, tlY = 0.48 * h
        let trX = 0.54 * w, trY = 0.43 * h
        let brX = 0.59 * w, brY = 0.57 * h
        let blX = 0.41 * w

        var path = Path()
        path.move(to: CGPoint(x: 0, y: tlY))
        path.addCurve(
            to: CGPoint(x: tlX, y: 0),
            control1: CGPoint(x: 0, y: tlY - tlY * k),
            control2: CGPoint(x: tlX - tlX * k, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: w, y: trY),
            control1: CGPoint(x: tlX + trX * k, y: 0),
            control2: CGPoint(x: w, y: trY - trY * k)
        )
        path.addCurve(
            to: CGPoint(x: w - brX, y: h),
            control1: CGPoint(x: w, y: trY + brY * k),
            control2: CGPoint(x: w - brX + brX * k, y: h)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: tlY),
            control1: CGPoint(x: w - brX - blX * k, y: h),
            control2: CGPoint(x: 0, y: tlY + (h - tlY) * k)
        )
        path.closeSubpath()
        return path
    }
}

/// One of the three angular highlights across the stone (`.facet`), `polygon(50% 0, 100% 90%, 10% 100%)`.
private struct Facet: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.5, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.width * 0.1, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// The full orb: stone body, facets, inner core with its five level bars, and the state rings.
/// Tapping it is the app's only control (see ContentView) -- the same overloaded orb as desktop.
struct OrbView: View {
    let phase: OrbPhase

    @State private var orbitAngle = 0.0
    @State private var listenPulse = false
    @State private var breathing = false
    @State private var speaking = false

    private var isDimmed: Bool { phase == .error }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                rings(size: size)
                stone(size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .saturation(isDimmed ? 0.3 : 1)
        .scaleEffect(breathing ? 1.035 : 1)
        .onAppear { startAnimations() }
        .onChange(of: phase) { _, _ in startAnimations() }
    }

    // MARK: - Stone body

    private func stone(size: CGFloat) -> some View {
        OrbShape()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x68635A), location: 0),
                        .init(color: Color(hex: 0x353733), location: 0.48),
                        .init(color: Color(hex: 0x171B19), location: 0.78),
                        .init(color: Color(hex: 0x090D0C), location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.15, y: 0),
                    endPoint: UnitPoint(x: 0.85, y: 1)
                )
            )
            .frame(width: size, height: size)
            .overlay { facets(size: size) }
            .overlay { innerLighting(size: size) }
            .overlay { innerRim(size: size) }
            .overlay { core(size: size) }
            .clipShape(OrbShape())
            .shadow(color: .black.opacity(0.72), radius: 45, x: 0, y: 36)
            .shadow(
                color: phase == .speaking ? RockyTheme.rust.opacity(0.25) : .clear,
                radius: 38
            )
    }

    /// The two inset shadows from `.rock-orb`: a warm highlight hugging the upper-left inner edge
    /// (`inset 14px 10px 30px rgba(255,205,143,.14)`) and a deep shadow pooling along the
    /// lower-right one (`inset -18px -20px 35px rgba(0,0,0,.55)`).
    ///
    /// SwiftUI has no inset shadow, so each is a thick blurred stroke of the outline, nudged by
    /// the CSS offset and masked back to the stone: shifting the ring down-right leaves more of
    /// it visible along the top-left edge, and vice versa -- which is exactly what those offsets
    /// mean for an inset shadow.
    private func innerLighting(size: CGFloat) -> some View {
        let scale = size / 270  // CSS pixel offsets were authored against a ~270px orb.
        return ZStack {
            // The rim darkening that makes the stone read as a sphere rather than a disc. Both
            // CSS inset shadows contribute this; a radial falloff carries it evenly around the
            // whole edge, with the directional strokes below adding the lighting's direction.
            RadialGradient(
                colors: [.clear, .clear, .black.opacity(0.78)],
                center: .center,
                startRadius: size * 0.26,
                endRadius: size * 0.52
            )
            OrbShape()
                .stroke(Color(hex: 0xFFCD8F).opacity(0.14), lineWidth: 30 * scale)
                .blur(radius: 15 * scale)
                .offset(x: 14 * scale, y: 10 * scale)
            OrbShape()
                .stroke(.black.opacity(0.55), lineWidth: 35 * scale)
                .blur(radius: 17 * scale)
                .offset(x: -18 * scale, y: -20 * scale)
        }
        .frame(width: size, height: size)
        .mask { OrbShape().frame(width: size, height: size) }
    }

    /// `.rock-orb::before` -- a faint amber outline set in from the edge and rotated.
    private func innerRim(size: CGFloat) -> some View {
        OrbShape()
            .stroke(Color(hex: 0xF3B369).opacity(0.15), lineWidth: 1)
            .frame(width: size * 0.78, height: size * 0.78)
            .rotationEffect(.degrees(17))
    }

    private func facets(size: CGFloat) -> some View {
        let gradient = LinearGradient(
            colors: [Color(hex: 0xF7C17C).opacity(0.14), Color(hex: 0x0C100F).opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        // Each facet's frame and offset come from its CSS `inset` (top/right/bottom/left).
        return ZStack {
            Facet().fill(gradient)
                .frame(width: size * 0.51, height: size * 0.48)
                .rotationEffect(.degrees(-22))
                .offset(x: -size * 0.105, y: -size * 0.23)
            Facet().fill(gradient)
                .frame(width: size * 0.47, height: size * 0.50)
                .rotationEffect(.degrees(28))
                .offset(x: size * 0.225, y: size * 0.17)
            Facet().fill(gradient)
                .frame(width: size * 0.43, height: size * 0.47)
                .rotationEffect(.degrees(12))
                .offset(x: -size * 0.215, y: size * 0.215)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Core and level bars

    private func core(size: CGFloat) -> some View {
        let coreSize = size * 0.38
        return ZStack {
            Circle()
                .fill(Color(hex: 0x040807).opacity(0.68))
                .overlay { Circle().stroke(Color(hex: 0x819D7E).opacity(0.13), lineWidth: 1) }
                .shadow(color: .black.opacity(0.72), radius: 15)
            HStack(spacing: coreSize * 0.07) {
                ForEach(0..<5, id: \.self) { index in
                    waveBar(coreSize: coreSize, index: index)
                }
            }
        }
        .frame(width: coreSize, height: coreSize)
    }

    private func waveBar(coreSize: CGFloat, index: Int) -> some View {
        let isSpeaking = phase == .speaking
        let tall = speaking && isSpeaking
        // Desktop staggers the five bars by -0.18s each; SwiftUI has no delay on a repeating
        // animation, so the same offset effect comes from alternating which bars are tall.
        let phaseFlip = index % 2 == 0
        let height = isSpeaking
            ? coreSize * (tall == phaseFlip ? 0.68 : 0.18)
            : coreSize * 0.20
        return RoundedRectangle(cornerRadius: 20)
            .fill(isSpeaking ? RockyTheme.amberBright : Color(hex: 0x4F4639))
            .frame(width: max(4, coreSize * 0.07), height: height)
            .opacity(isSpeaking ? 0.68 : 0.12)
            .shadow(color: isSpeaking ? RockyTheme.amber.opacity(0.52) : .clear, radius: 6)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: speaking)
    }

    // MARK: - State rings (`.rock-orb::after`)

    @ViewBuilder
    private func rings(size: CGFloat) -> some View {
        let ringSize = size * 1.18
        switch phase {
        case .connecting:
            // CSS lights this ring per-edge -- `border-color: top right bottom left` of
            // .2 / .72 / .2 / .08 -- so it is really one bright arc that sweeps around, not an
            // even glow. SwiftUI's angular gradient starts at 3 o'clock and runs clockwise.
            OrbShape()
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: RockyTheme.amberBright.opacity(0.72), location: 0),
                            .init(color: RockyTheme.amber.opacity(0.2), location: 0.25),
                            .init(color: RockyTheme.amberBright.opacity(0.08), location: 0.5),
                            .init(color: RockyTheme.amber.opacity(0.2), location: 0.75),
                            .init(color: RockyTheme.amberBright.opacity(0.72), location: 1),
                        ],
                        center: .center
                    ),
                    lineWidth: 2
                )
                .frame(width: ringSize, height: ringSize)
                .opacity(0.72)
                .rotationEffect(.degrees(orbitAngle))
        case .listening:
            OrbShape()
                .stroke(RockyTheme.mint.opacity(0.7), lineWidth: 2)
                .frame(width: ringSize, height: ringSize)
                .scaleEffect(listenPulse ? 1.025 : 0.97)
                .opacity(listenPulse ? 0.78 : 0.32)
                .shadow(color: RockyTheme.mint.opacity(0.2), radius: 14)
        case .idle, .speaking, .error:
            EmptyView()
        }
    }

    private func startAnimations() {
        breathing = false
        listenPulse = false
        speaking = false
        switch phase {
        case .connecting:
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                orbitAngle += 360
            }
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                breathing = true
            }
        case .listening:
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                listenPulse = true
            }
        case .speaking:
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                speaking = true
            }
        case .idle, .error:
            break
        }
    }
}

#Preview {
    ZStack {
        RockyTheme.background
        StarField()
        OrbView(phase: .listening).frame(width: 300, height: 300)
    }
}
