import SwiftUI

/// Maps the full edge slider linearly between the two mechanically safe endpoints. There is no
/// stored or visible center: the midpoint is simply halfway between min and max.
struct ServoCalibration: Equatable {
    let minimum: Int
    let maximum: Int
    let reversed: Bool

    init(minimum: Int, maximum: Int, reversed: Bool) {
        let safeMinimum = max(0, min(179, minimum))
        self.minimum = safeMinimum
        self.maximum = max(safeMinimum + 1, min(180, maximum))
        self.reversed = reversed
    }

    func angle(for position: Double) -> Int {
        var directed = max(-1, min(1, position))
        if reversed { directed *= -1 }
        let fraction = (directed + 1) / 2
        return Int((Double(minimum) + Double(maximum - minimum) * fraction).rounded())
    }
}

/// Geometry for the edge controls. Unlike a horizontally laid-out `Slider` rotated 90 degrees,
/// this makes hit testing and drawing use the same coordinate system.
enum VerticalControlMath {
    static func position(atY y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return max(-1, min(1, 1 - (2 * Double(y / height))))
    }

    static func y(for position: Double, height: CGFloat) -> CGFloat {
        CGFloat((1 - max(-1, min(1, position))) / 2) * height
    }
}

struct VerticalDragControl: View {
    @Binding var value: Double
    let springReturns: Bool
    let editingChanged: (Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackHeight = max(1, geometry.size.height - 18)
            let thumbY = 9 + VerticalControlMath.y(for: value, height: trackHeight)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(RockyTheme.mint.opacity(0.16))
                    .frame(width: 5, height: trackHeight)
                    .offset(y: 9)
                Capsule()
                    .fill(RockyTheme.amberBright)
                    .frame(width: 26, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(y: thumbY - 9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        value = VerticalControlMath.position(
                            atY: gesture.location.y - 9, height: trackHeight
                        )
                        if !dragging {
                            dragging = true
                            editingChanged(true)
                        }
                    }
                    .onEnded { _ in
                        if springReturns {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                                value = 0
                            }
                        }
                        dragging = false
                        editingChanged(false)
                    }
            )
        }
        .frame(width: 34, height: 174)
    }
}

/// S3/S4 are the dedicated servo sockets used by Makeblock's grabber build. Previously saved safe
/// endpoints and direction remain in effect, but calibration is intentionally absent from the
/// everyday control surface.
struct ServoSideControl: View {
    let port: String
    let send: (_ angle: Int, _ immediately: Bool) -> Void

    @AppStorage private var minimum: Int
    @AppStorage private var maximum: Int
    @AppStorage private var reversed: Bool
    @State private var position = 0.0

    init(port: String, send: @escaping (_ angle: Int, _ immediately: Bool) -> Void) {
        self.port = port
        self.send = send
        _minimum = AppStorage(wrappedValue: 0, "servo.\(port).minimum")
        _maximum = AppStorage(wrappedValue: 180, "servo.\(port).maximum")
        _reversed = AppStorage(wrappedValue: false, "servo.\(port).reversed")
    }

    private var calibration: ServoCalibration {
        ServoCalibration(minimum: minimum, maximum: maximum, reversed: reversed)
    }

    private var angle: Int { calibration.angle(for: position) }

    var body: some View {
        VStack(spacing: 7) {
            Text(port)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.mintBright.opacity(0.9))

            VerticalDragControl(value: $position, springReturns: false) { editing in
                if !editing { send(angle, true) }
            }
            .onChange(of: position) { _, _ in send(angle, false) }
            .accessibilityLabel("Servo on port \(port)")
            .accessibilityValue("\(angle) degrees")

            Text("\(angle)°")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(0.8))
        }
        .padding(.vertical, 9)
        .frame(width: 54)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RockyTheme.ink.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(RockyTheme.mint.opacity(0.14), lineWidth: 1)
                }
        }
    }
}

struct DriveAxisSideControl: View {
    let title: String
    let high: String
    let low: String
    @Binding var value: Double
    let editingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 7) {
            Text(high)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(0.58))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.86))
            VerticalDragControl(
                value: $value, springReturns: true, editingChanged: editingChanged
            )
            Text(low)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(0.58))
            Text("\(Int(value * 100))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(0.8))
        }
        .padding(.vertical, 9)
        .frame(width: 54)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RockyTheme.ink.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(RockyTheme.mint.opacity(0.14), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title == "DRIVE" ? "Drive forward and backward" : "Steer left and right")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
