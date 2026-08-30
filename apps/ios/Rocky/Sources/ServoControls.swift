import Foundation
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
    static let maximumInputStep: CGFloat = 12
    static func position(atY y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return max(-1, min(1, 1 - (2 * Double(y / height))))
    }

    static func y(for position: Double, height: CGFloat) -> CGFloat {
        CGFloat((1 - max(-1, min(1, position))) / 2) * height
    }

    static func relativePosition(
        startingAt start: Double, translationY: CGFloat, height: CGFloat
    ) -> Double {
        guard height > 0 else { return max(-1, min(1, start)) }
        return max(-1, min(1, start - (2 * Double(translationY / height))))
    }

    static func incrementalPosition(
        current: Double, deltaY: CGFloat, height: CGFloat
    ) -> (position: Double, acceptedDeltaY: CGFloat) {
        let accepted = max(-maximumInputStep, min(maximumInputStep, deltaY))
        return (relativePosition(startingAt: current, translationY: accepted, height: height), accepted)
    }
}

enum DriveControlResponse {
    static func throttle(_ raw: Double) -> Double {
        shaped(raw, deadZone: 0.14, exponent: 1.35)
    }

    static func steering(_ raw: Double) -> Double {
        shaped(raw, deadZone: 0.20, exponent: 1.7)
    }

    private static func shaped(_ raw: Double, deadZone: Double, exponent: Double) -> Double {
        let bounded = max(-1, min(1, raw))
        let magnitude = abs(bounded)
        guard magnitude > deadZone else { return 0 }
        let normalized = (magnitude - deadZone) / (1 - deadZone)
        return (bounded < 0 ? -1 : 1) * pow(normalized, exponent)
    }
}

struct VerticalDragControl: View {
    @Binding var value: Double
    let springReturns: Bool
    let traceID: String
    let response: (Double) -> Double
    let editingChanged: (Bool) -> Void
    @State private var dragging = false
    @State private var lastDragLocationY = 0.0
    @State private var lastTraceAt = Date.distantPast

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
                        if !dragging {
                            dragging = true
                            lastDragLocationY = gesture.location.y
                            trace(
                                phase: "began", translationY: gesture.translation.height,
                                raw: value, always: true
                            )
                            editingChanged(true)
                        }
                        let physicalDelta = gesture.location.y - lastDragLocationY
                        let update = VerticalControlMath.incrementalPosition(
                            current: value, deltaY: physicalDelta, height: trackHeight
                        )
                        value = update.position
                        lastDragLocationY = gesture.location.y
                        if abs(physicalDelta) > VerticalControlMath.maximumInputStep {
                            RockyLog.write(
                                "control[\(traceID)]: rejected touch discontinuity "
                                    + "delta=\(Int(physicalDelta.rounded()))pt "
                                    + "accepted=\(Int(update.acceptedDeltaY.rounded()))pt"
                            )
                        }
                        trace(
                            phase: "changed", translationY: gesture.translation.height,
                            raw: value
                        )
                    }
                    .onEnded { gesture in
                        trace(
                            phase: "ended", translationY: gesture.translation.height,
                            raw: value, always: true
                        )
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

    private func trace(
        phase: String, translationY: CGFloat, raw: Double, always: Bool = false
    ) {
        let now = Date()
        guard always || now.timeIntervalSince(lastTraceAt) >= 0.15 else { return }
        lastTraceAt = now
        RockyLog.write(
            "control[\(traceID)]: \(phase) dy=\(Int(translationY.rounded()))pt "
                + "raw=\(String(format: "%.3f", raw)) "
                + "output=\(String(format: "%.3f", response(raw)))"
        )
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
            VStack(spacing: 2) {
                Text(port)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(RockyTheme.mintBright.opacity(0.9))
            }
            .frame(height: 32)

            VerticalDragControl(
                value: $position,
                springReturns: false,
                traceID: port,
                response: { Double(calibration.angle(for: $0)) }
            ) { editing in
                if !editing { send(angle, true) }
            }
            .onChange(of: position) { _, _ in send(angle, false) }
            .accessibilityLabel("Servo on port \(port)")
            .accessibilityValue("\(angle) degrees")

            VStack(spacing: 2) {
                Text("\(angle)°")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RockyTheme.mint.opacity(0.8))
            }
            .frame(height: 32)
        }
        .padding(.vertical, 9)
        .frame(width: 54, height: 256)
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
    let response: (Double) -> Double
    let editingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 7) {
            VStack(spacing: 2) {
                Text(high)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RockyTheme.mint.opacity(0.58))
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RockyTheme.amberBright.opacity(0.86))
            }
            .frame(height: 32)
            VerticalDragControl(
                value: $value,
                springReturns: true,
                traceID: title.lowercased(),
                response: response,
                editingChanged: editingChanged
            )
            VStack(spacing: 2) {
                Text(low)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RockyTheme.mint.opacity(0.58))
                Text("\(Int(response(value) * 100))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(RockyTheme.mint.opacity(0.8))
            }
            .frame(height: 32)
        }
        .padding(.vertical, 9)
        .frame(width: 54, height: 256)
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
        .accessibilityValue("\(Int(response(value) * 100)) percent")
    }
}
