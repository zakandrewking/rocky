import SwiftUI

struct PersonalitySelectorView: View {
    @ObservedObject var store: PersonalityStore
    @Binding var selection: String
    let canChange: Bool
    let onChange: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editorDraft: EditablePersonality?
    @State private var creatingProfile = false
    @State private var pendingDelete: EditablePersonality?

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background
                StarField()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Rocky stays Rocky. Make other personalities here, tune their character, and give each one an ElevenLabs voice.")
                            .font(.system(size: 15))
                            .foregroundStyle(RockyTheme.mintBright.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)

                        if !hasElevenLabsKey {
                            Text("ElevenLabs is not configured in this build. You can create personalities now, but they need ELEVENLABS_API_KEY before they can speak.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RockyTheme.amberBright.opacity(0.86))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        rockyButton

                        ForEach(store.customProfiles) { profile in
                            customButton(profile)
                        }

                        Button {
                            creatingProfile = true
                            editorDraft = EditablePersonality.draft()
                        } label: {
                            Label("Create personality", systemImage: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(RockyTheme.amberBright)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(RockyTheme.deep.opacity(0.76))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(
                                                    RockyTheme.amber.opacity(0.42),
                                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                                                )
                                        }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChange)
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
        .sheet(item: $editorDraft) { profile in
            PersonalityEditorView(profile: profile, isNew: creatingProfile) { saved in
                store.save(saved)
                if creatingProfile || selection == saved.id {
                    selection = saved.id
                    onChange(saved.id)
                }
                editorDraft = nil
            }
            .id(profile.id)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this personality")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let pendingDelete else { return }
                let wasSelected = selection == pendingDelete.id
                store.delete(id: pendingDelete.id)
                self.pendingDelete = nil
                if wasSelected {
                    selection = PersonalityCatalog.defaultCharacterID
                    onChange(selection)
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the personality and its slider settings from this phone.")
        }
    }

    private var hasElevenLabsKey: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsKey") as? String) ?? "").isEmpty
    }

    private var rockyButton: some View {
        let profile = PersonalityCatalog.rockyProfile
        return card(
            name: profile.name,
            summary: profile.summary,
            detail: "Default · fixed · Hume voice",
            selected: selection == profile.id,
            editable: false,
            select: { select(profile.id) },
            edit: nil
        )
    }

    private func customButton(_ profile: EditablePersonality) -> some View {
        let voiceName = profile.voiceName ?? ElevenLabsVoiceOption.resolved(profile.voiceID).name
        return card(
            name: profile.name,
            summary: profile.summary,
            detail: "ElevenLabs · \(voiceName)",
            selected: selection == profile.id,
            editable: true,
            select: { select(profile.id) },
            edit: {
                creatingProfile = false
                editorDraft = profile
            }
        )
        .contextMenu {
            Button {
                creatingProfile = false
                editorDraft = profile
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                let copy = store.duplicate(profile)
                selection = copy.id
                onChange(copy.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) { pendingDelete = profile } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func select(_ id: String) {
        guard canChange, selection != id else { return }
        selection = id
        onChange(id)
    }

    private func card(
        name: String,
        summary: String,
        detail: String,
        selected: Bool,
        editable: Bool,
        select: @escaping () -> Void,
        edit: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: select) {
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
                        Text(name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(RockyTheme.mintBright)
                        Text(summary)
                            .font(.system(size: 14))
                            .foregroundStyle(RockyTheme.mint.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RockyTheme.amberBright.opacity(0.62))
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canChange)

            if let edit {
                Button(action: edit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RockyTheme.mintBright.opacity(0.76))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(RockyTheme.ink.opacity(0.62)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(name)")
                .disabled(!canChange)
            } else if selected {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name). \(summary). \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PersonalityEditorView: View {
    private enum IdentityGenerationState: Equatable {
        case initial
        case loading
        case ready
        case failed
    }

    @State var profile: EditablePersonality
    let isNew: Bool
    let onSave: (EditablePersonality) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var identityGenerationState = IdentityGenerationState.initial
    @State private var generationError: String?

    init(
        profile: EditablePersonality,
        isNew: Bool,
        onSave: @escaping (EditablePersonality) -> Void
    ) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var isGeneratingIdentity: Bool {
        identityGenerationState == .loading
            || (isNew && identityGenerationState == .initial)
    }

    private var identityIsReady: Bool {
        !isNew || identityGenerationState == .ready
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background
                StarField()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        editorSection("Identity") {
                            VStack(alignment: .leading, spacing: 8) {
                                if isGeneratingIdentity {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .tint(RockyTheme.amberBright)
                                        Text("Dreaming up someone new…")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(RockyTheme.mintBright)
                                    }
                                    .padding(.vertical, 12)
                                    .task {
                                        guard isNew, identityGenerationState == .initial else { return }
                                        await performGeneration()
                                    }
                                } else if identityIsReady || !isNew {
                                    Text(profile.name)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(RockyTheme.mintBright)
                                    Text(profile.concept)
                                        .font(.system(size: 15))
                                        .foregroundStyle(RockyTheme.mint.opacity(0.78))
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("No identity yet")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(RockyTheme.mintBright)
                                }
                            }
                            .padding(14)
                            .background(fieldBackground)

                            Button {
                                Task { await startGeneratingIdentity() }
                            } label: {
                                Label("AI-generate from sliders", systemImage: "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RockyTheme.amberBright)
                            }
                            .buttonStyle(.plain)
                            .disabled(isGeneratingIdentity)

                            Text("Move the sliders, then regenerate to weave those traits into a new name and paragraph.")
                                .font(.system(size: 11))
                                .foregroundStyle(RockyTheme.mint.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)

                            if let generationError {
                                Text(generationError)
                                    .font(.system(size: 12))
                                    .foregroundStyle(RockyTheme.amberBright.opacity(0.86))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        editorSection("Personality") {
                            TraitSlider(title: "Warmth", low: "reserved", high: "affectionate", value: $profile.traits.warmth)
                            TraitSlider(title: "Energy", low: "still", high: "exuberant", value: $profile.traits.energy)
                            TraitSlider(title: "Humor", low: "earnest", high: "mischievous", value: $profile.traits.humor)
                            TraitSlider(title: "Curiosity", low: "self-contained", high: "inquisitive", value: $profile.traits.curiosity)
                            TraitSlider(title: "Talkativeness", low: "compact", high: "expansive", value: $profile.traits.talkativeness)
                        }

                        editorSection("ElevenLabs voice") {
                            NavigationLink {
                                VoiceChooserView(
                                    voiceID: $profile.voiceID,
                                    voiceName: $profile.voiceName,
                                    personalityName: profile.name,
                                    traits: profile.traits
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(RockyTheme.amberBright)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.voiceName ?? ElevenLabsVoiceOption.resolved(profile.voiceID).name)
                                            .foregroundStyle(RockyTheme.mintBright)
                                        Text("Choose from your voices or create a new one")
                                            .font(.system(size: 12))
                                            .foregroundStyle(RockyTheme.mint.opacity(0.66))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(RockyTheme.mint.opacity(0.5))
                                }
                                .padding(12)
                                .background(fieldBackground)
                            }
                            .buttonStyle(.plain)

                            TraitSlider(
                                title: "Voice consistency",
                                low: "expressive",
                                high: "steady",
                                value: $profile.voiceStability
                            )
                            TraitSlider(
                                title: "Speaking speed",
                                low: "slow",
                                high: "quick",
                                value: Binding(
                                    get: { (profile.voiceSpeed - 0.7) / 0.5 },
                                    set: { profile.voiceSpeed = 0.7 + $0 * 0.5 }
                                )
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isNew ? "New personality" : "Edit \(profile.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RockyTheme.ink.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = profile
                        saved.normalize()
                        onSave(saved)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(RockyTheme.amberBright)
                    .disabled(isGeneratingIdentity || (isNew && !identityIsReady))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func startGeneratingIdentity() async {
        guard !isGeneratingIdentity else { return }
        identityGenerationState = .loading
        await performGeneration()
    }

    private func performGeneration() async {
        identityGenerationState = .loading
        generationError = nil
        do {
            let identity = try await PersonalityGenerator.generate(for: profile.traits)
            profile.name = identity.name
            profile.concept = identity.concept
            identityGenerationState = .ready
        } catch {
            generationError = "Couldn’t generate that one. Check the connection and tap the sparkle button to retry."
            identityGenerationState = .failed
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(RockyTheme.ink.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(RockyTheme.mint.opacity(0.14), lineWidth: 1)
            }
    }

    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright.opacity(0.78))
            content()
        }
    }
}

private struct TraitSlider: View {
    let title: String
    let low: String
    let high: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RockyTheme.mintBright)
                Spacer()
                Text("\(Int(value * 100))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RockyTheme.amberBright.opacity(0.72))
            }
            Slider(value: $value, in: 0...1)
                .tint(RockyTheme.amber)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(RockyTheme.mint.opacity(0.54))
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(RockyTheme.ink.opacity(0.54))
        }
    }
}

#Preview {
    PersonalitySelectorView(
        store: PersonalityStore(),
        selection: .constant("rocky"),
        canChange: true,
        onChange: { _ in }
    )
}
