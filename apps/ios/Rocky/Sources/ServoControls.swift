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

/// S3/S4 are the dedicated servo sockets used by Makeblock's grabber build. Calibration adjusts
/// only the safe endpoints; horn alignment establishes the mechanical midpoint before software.
struct ServoSideControl: View {
    let port: String
    let send: (_ angle: Int, _ immediately: Bool) -> Void

    @AppStorage private var minimum: Int
    @AppStorage private var maximum: Int
    @AppStorage private var reversed: Bool
    @State private var position = 0.0
    @State private var showingCalibration = false

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
            Button { showingCalibration = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RockyTheme.amberBright.opacity(0.86))
            .accessibilityLabel("Calibrate servo on \(port)")

            Text(port)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RockyTheme.mintBright.opacity(0.9))

            Slider(
                value: $position,
                in: -1...1,
                onEditingChanged: { editing in
                    if !editing { send(angle, true) }
                }
            )
            .tint(RockyTheme.amberBright)
            .frame(width: 174)
            .rotationEffect(.degrees(-90))
            .frame(width: 34, height: 174)
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
        .sheet(isPresented: $showingCalibration) {
            ServoCalibrationView(
                port: port,
                minimum: $minimum,
                maximum: $maximum,
                reversed: $reversed,
                test: send
            )
            .presentationDetents([.height(390)])
            .onDisappear {
                let safe = calibration
                let returnAngle = safe.angle(for: position)
                RockyLog.write(
                    "servo: \(port) calibration saved min=\(safe.minimum)° "
                        + "max=\(safe.maximum)° reversed=\(safe.reversed); "
                        + "returning to \(returnAngle)°"
                )
                send(returnAngle, true)
            }
        }
    }
}

private struct ServoCalibrationView: View {
    let port: String
    @Binding var minimum: Int
    @Binding var maximum: Int
    @Binding var reversed: Bool
    let test: (_ angle: Int, _ immediately: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    private var minimumBinding: Binding<Int> {
        Binding(get: { minimum }, set: { minimum = max(0, min(maximum - 1, $0)) })
    }

    private var maximumBinding: Binding<Int> {
        Binding(get: { maximum }, set: { maximum = max(minimum + 1, min(180, $0)) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Safe travel") {
                    Button("Set horn alignment position (90°)") {
                        RockyLog.write("servo: \(port) requested 90° horn alignment position")
                        test(90, true)
                    }
                    ServoCalibrationSlider(
                        title: "Minimum", value: minimumBinding, range: 0...179, test: test
                    )
                    ServoCalibrationSlider(
                        title: "Maximum", value: maximumBinding, range: 1...180, test: test
                    )
                    Toggle("Reverse direction", isOn: $reversed)
                }
                Section {
                    Button("Begin safely around 90°") {
                        minimum = 85
                        maximum = 95
                        reversed = false
                        RockyLog.write(
                            "servo: \(port) calibration narrowed to 85–95° for safe expansion"
                        )
                        test(90, true)
                    }
                } footer: {
                    Text(
                        "With the horn removed, use the alignment action first. Then reinstall the "
                            + "horn, begin safely around 90°, and expand Min and Max slowly. Stop "
                            + "before buzzing or binding."
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
                    minimum: minimum, maximum: maximum, reversed: reversed
                )
                minimum = safe.minimum
                maximum = safe.maximum
            }
        }
    }
}

private struct ServoCalibrationSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let test: (_ angle: Int, _ immediately: Bool) -> Void

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
                Text("\(value)°")
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
            .accessibilityValue("\(value) degrees")
        }
        .padding(.vertical, 2)
    }
}
