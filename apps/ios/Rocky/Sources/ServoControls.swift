import SwiftUI

/// CyberOS names the pulse span 0...180 even when a wide-travel servo turns farther than that.
/// Keep command units at the wire boundary and show the person the accessory's physical degrees.
struct ServoTravelProfile: Equatable {
    let physicalMaximum: Int

    static func forPort(_ port: String) -> ServoTravelProfile {
        ServoTravelProfile(physicalMaximum: port.uppercased() == "S3" ? 270 : 180)
    }

    func physicalAngle(forCommandAngle angle: Int) -> Int {
        Int((Double(max(0, min(180, angle))) * Double(physicalMaximum) / 180).rounded())
    }
}

/// Maps a friendly centered control (-1...1) onto a servo's real, often asymmetric travel.
/// Keeping this pure makes calibration behavior testable without a robot or SwiftUI lifecycle.
struct ServoCalibration: Equatable {
    let minimum: Int
    let center: Int
    let maximum: Int
    let reversed: Bool

    init(minimum: Int, center: Int, maximum: Int, reversed: Bool) {
        let safeMinimum = max(0, min(178, minimum))
        let safeMaximum = max(safeMinimum + 2, min(180, maximum))
        self.minimum = safeMinimum
        self.maximum = safeMaximum
        self.center = max(safeMinimum + 1, min(safeMaximum - 1, center))
        self.reversed = reversed
    }

    func angle(for position: Double) -> Int {
        var directed = max(-1, min(1, position))
        if reversed { directed *= -1 }
        let result: Double
        if directed < 0 {
            result = Double(center) + Double(center - minimum) * directed
        } else {
            result = Double(center) + Double(maximum - center) * directed
        }
        return max(0, min(180, Int(result.rounded())))
    }
}

/// One compact edge control. Main interaction stays intentionally simple; the gear opens the
/// persistent mechanical calibration needed when horns are mounted off-center or mirrored.
struct ServoSideControl: View {
    let port: String
    let connected: Bool
    let send: (_ commandAngle: Int, _ physicalAngle: Int, _ immediately: Bool) -> Void

    @AppStorage private var minimum: Int
    @AppStorage private var center: Int
    @AppStorage private var maximum: Int
    @AppStorage private var reversed: Bool
    @State private var position = 0.0
    @State private var showingCalibration = false

    init(
        port: String,
        connected: Bool,
        send: @escaping (_ commandAngle: Int, _ physicalAngle: Int, _ immediately: Bool) -> Void
    ) {
        self.port = port
        self.connected = connected
        self.send = send
        _minimum = AppStorage(wrappedValue: 0, "servo.\(port).minimum")
        _center = AppStorage(wrappedValue: 90, "servo.\(port).center")
        _maximum = AppStorage(wrappedValue: 180, "servo.\(port).maximum")
        _reversed = AppStorage(wrappedValue: false, "servo.\(port).reversed")
    }

    private var calibration: ServoCalibration {
        ServoCalibration(minimum: minimum, center: center, maximum: maximum, reversed: reversed)
    }

    private var profile: ServoTravelProfile { .forPort(port) }
    private var commandAngle: Int { calibration.angle(for: position) }
    private var physicalAngle: Int { profile.physicalAngle(forCommandAngle: commandAngle) }

    private func sendCurrent(_ commandAngle: Int, immediately: Bool) {
        send(commandAngle, profile.physicalAngle(forCommandAngle: commandAngle), immediately)
    }

    var body: some View {
        VStack(spacing: 7) {
            Button {
                showingCalibration = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RockyTheme.amberBright.opacity(connected ? 0.86 : 0.38))
            .accessibilityLabel("Calibrate \(port)")

            Text(port)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.mintBright.opacity(connected ? 0.9 : 0.42))

            Slider(
                value: $position,
                in: -1...1,
                onEditingChanged: { editing in
                    if !editing { sendCurrent(commandAngle, immediately: true) }
                }
            )
            .tint(RockyTheme.amberBright)
            .frame(width: 174)
            .rotationEffect(.degrees(-90))
            .frame(width: 34, height: 174)
            .disabled(!connected)
            .onChange(of: position) { _, _ in
                guard connected else { return }
                sendCurrent(commandAngle, immediately: false)
            }
            .accessibilityLabel("Servo port \(port)")
            .accessibilityValue("\(physicalAngle) degrees")

            Text("\(physicalAngle)°")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(connected ? 0.8 : 0.38))

            Button("center") {
                position = 0
                sendCurrent(calibration.center, immediately: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(RockyTheme.amberBright.opacity(connected ? 0.72 : 0.3))
            .disabled(!connected)
        }
        .padding(.vertical, 9)
        .frame(width: 54)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RockyTheme.ink.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(RockyTheme.mint.opacity(connected ? 0.14 : 0.07), lineWidth: 1)
                }
        }
        .opacity(connected ? 1 : 0.72)
        .sheet(isPresented: $showingCalibration) {
            ServoCalibrationView(
                port: port,
                minimum: $minimum,
                center: $center,
                maximum: $maximum,
                reversed: $reversed,
                profile: profile,
                test: { commandAngle, immediately in
                    let physicalAngle = profile.physicalAngle(forCommandAngle: commandAngle)
                    RockyLog.write(
                        "servo: \(port) calibration testing \(physicalAngle)° physical "
                            + "(command \(commandAngle)°)"
                    )
                    send(commandAngle, physicalAngle, immediately)
                }
            )
            .presentationDetents([.height(470)])
            .onDisappear {
                let target = commandAngle
                let physicalTarget = profile.physicalAngle(forCommandAngle: target)
                RockyLog.write(
                    "servo: \(port) calibration saved physical="
                        + "\(profile.physicalAngle(forCommandAngle: calibration.minimum))/"
                        + "\(profile.physicalAngle(forCommandAngle: calibration.center))/"
                        + "\(profile.physicalAngle(forCommandAngle: calibration.maximum))° "
                        + "command=\(calibration.minimum)/\(calibration.center)/"
                        + "\(calibration.maximum) reversed=\(calibration.reversed); "
                        + "returning to \(physicalTarget)° physical (command \(target)°)"
                )
                send(target, physicalTarget, true)
            }
        }
    }
}

private struct ServoCalibrationView: View {
    let port: String
    @Binding var minimum: Int
    @Binding var center: Int
    @Binding var maximum: Int
    @Binding var reversed: Bool
    let profile: ServoTravelProfile
    let test: (_ commandAngle: Int, _ immediately: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    private var physicalMinimum: Int { profile.physicalAngle(forCommandAngle: minimum) }
    private var physicalCenter: Int { profile.physicalAngle(forCommandAngle: center) }
    private var physicalMaximum: Int { profile.physicalAngle(forCommandAngle: maximum) }

    private var minimumBinding: Binding<Int> {
        Binding(get: { minimum }, set: { minimum = max(0, min(center - 1, $0)) })
    }

    private var centerBinding: Binding<Int> {
        Binding(get: { center }, set: { center = max(minimum + 1, min(maximum - 1, $0)) })
    }

    private var maximumBinding: Binding<Int> {
        Binding(get: { maximum }, set: { maximum = max(center + 1, min(180, $0)) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Travel") {
                    ServoCalibrationSlider(
                        title: "Minimum",
                        physicalAngle: physicalMinimum,
                        value: minimumBinding,
                        range: 0...179,
                        test: test
                    )
                    ServoCalibrationSlider(
                        title: "Center",
                        physicalAngle: physicalCenter,
                        value: centerBinding,
                        range: 1...179,
                        test: test
                    )
                    ServoCalibrationSlider(
                        title: "Maximum",
                        physicalAngle: physicalMaximum,
                        value: maximumBinding,
                        range: 1...180,
                        test: test
                    )
                    Toggle("Reverse direction", isOn: $reversed)
                }
                Section {
                    Button(
                        "Reset to 0° / \(profile.physicalMaximum / 2)° / "
                            + "\(profile.physicalMaximum)°"
                    ) {
                        minimum = 0
                        center = 90
                        maximum = 180
                        reversed = false
                        test(center, true)
                    }
                } footer: {
                    Text(
                        "Move each slider slowly. \(port) follows that calibration point live; "
                            + "the limits cannot cross the center."
                    )
                }
            }
            .navigationTitle("Calibrate \(port)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                let safe = ServoCalibration(
                    minimum: minimum,
                    center: center,
                    maximum: maximum,
                    reversed: reversed
                )
                minimum = safe.minimum
                center = safe.center
                maximum = safe.maximum
            }
        }
    }
}

private struct ServoCalibrationSlider: View {
    let title: String
    let physicalAngle: Int
    @Binding var value: Int
    let range: ClosedRange<Int>
    let test: (_ commandAngle: Int, _ immediately: Bool) -> Void

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { newValue in
                value = Int(newValue.rounded())
                test(value, false)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(physicalAngle)°")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: sliderValue,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1,
                onEditingChanged: { editing in
                    if !editing { test(value, true) }
                }
            )
            .tint(RockyTheme.amberBright)
            .accessibilityLabel("\(title) travel")
            .accessibilityValue("\(physicalAngle) degrees")
        }
        .padding(.vertical, 2)
    }
}
