import SwiftUI

struct PersonalitySelectorView: View {
    @Binding var selection: String
    let canChange: Bool
    let onChange: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background
                StarField()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose who is here with you. Each personality has its own voice, cadence, and point of view.")
                            .font(.system(size: 15))
                            .foregroundStyle(RockyTheme.mintBright.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)

                        if !canChange {
                            Text("Pause the current conversation before choosing someone else.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RockyTheme.amberBright.opacity(0.8))
                        }

                        ForEach(PersonalityCatalog.profiles) { profile in
                            personalityButton(profile)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Personality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RockyTheme.ink.opacity(0.92), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RockyTheme.amberBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func personalityButton(_ profile: PersonalityProfile) -> some View {
        let selected = profile.id == PersonalityCatalog.resolvedID(selection)
        return Button {
            guard canChange else { return }
            guard !selected else { return }
            selection = profile.id
            onChange(profile.id)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(selected ? RockyTheme.amber.opacity(0.24) : RockyTheme.teal.opacity(0.16))
                    Image(systemName: selected ? "sparkles" : "circle.dotted")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(selected ? RockyTheme.amberBright : RockyTheme.mint.opacity(0.7))
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RockyTheme.mintBright)
                    Text(profile.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(RockyTheme.mint.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(RockyTheme.amberBright)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(RockyTheme.deep.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                selected ? RockyTheme.amber.opacity(0.72) : RockyTheme.mint.opacity(0.14),
                                lineWidth: selected ? 1.5 : 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .accessibilityLabel("Choose \(profile.name). \(profile.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    PersonalitySelectorView(selection: .constant("rocky"), canChange: true, onChange: { _ in })
}
