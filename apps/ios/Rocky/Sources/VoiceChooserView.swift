import SwiftUI

struct VoiceChooserView: View {
    @Binding var voiceID: String
    @Binding var voiceName: String?
    let personalityName: String
    let traits: PersonalityTraits

    @StateObject private var library = ElevenLabsVoiceLibrary()
    @StateObject private var player = VoicePreviewPlayer()
    @State private var showingDesigner = false

    var body: some View {
        ZStack {
            RockyTheme.background
            StarField()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Button {
                        showingDesigner = true
                    } label: {
                        Label("Create a new voice", systemImage: "waveform.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RockyTheme.amberBright)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(cardBackground(selected: false))
                    }
                    .buttonStyle(.plain)

                    Text("Choose a voice")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RockyTheme.mint.opacity(0.7))
                        .padding(.top, 8)

                    ForEach(allVoices) { voice in
                        voiceRow(voice)
                    }

                    if library.loading {
                        ProgressView("Loading your ElevenLabs voices…")
                            .tint(RockyTheme.amberBright)
                            .foregroundStyle(RockyTheme.mint)
                            .padding()
                    }
                    if let error = library.errorMessage {
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(RockyTheme.amberBright)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.loadVoices() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showingDesigner) {
            VoiceDesignerView(
                library: library,
                personalityName: personalityName,
                traits: traits
            ) { voice in
                voiceID = voice.id
                voiceName = voice.name
                showingDesigner = false
            }
        }
    }

    private var allVoices: [ElevenLabsLibraryVoice] {
        var seen = Set<String>()
        let builtIn = ElevenLabsVoiceOption.choices.map {
            ElevenLabsLibraryVoice(id: $0.id, name: $0.name, summary: $0.summary, previewURL: nil)
        }
        let selected: [ElevenLabsLibraryVoice] = builtIn.contains(where: { $0.id == voiceID })
            || library.voices.contains(where: { $0.id == voiceID })
            ? []
            : [ElevenLabsLibraryVoice(
                id: voiceID,
                name: voiceName ?? "Custom voice",
                summary: "Saved with this personality",
                previewURL: nil
            )]
        return (selected + builtIn + library.voices).filter { seen.insert($0.id).inserted }
    }

    private func voiceRow(_ voice: ElevenLabsLibraryVoice) -> some View {
        HStack(spacing: 12) {
            Button {
                voiceID = voice.id
                voiceName = voice.name
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: voiceID == voice.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(voiceID == voice.id ? RockyTheme.amberBright : RockyTheme.mint.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.name).foregroundStyle(RockyTheme.mintBright)
                        Text(voice.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(RockyTheme.mint.opacity(0.66))
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if voice.previewURL != nil {
                Button {
                    Task {
                        if let data = await library.preview(voice) { player.play(data, id: voice.id) }
                    }
                } label: {
                    Image(systemName: player.playingID == voice.id ? "speaker.wave.2.fill" : "play.fill")
                        .foregroundStyle(RockyTheme.amberBright)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(voice.name)")
            }
        }
        .padding(14)
        .background(cardBackground(selected: voiceID == voice.id))
    }

    private func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(RockyTheme.deep.opacity(0.9))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? RockyTheme.amber.opacity(0.7) : RockyTheme.mint.opacity(0.14))
            }
    }
}

private struct VoiceDesignerView: View {
    private enum Presentation: String, CaseIterable, Identifiable {
        case feminine, androgynous, masculine
        var id: String { rawValue }
    }

    private enum Accent: String, CaseIterable, Identifiable {
        case american = "American"
        case british = "British"
        case irish = "Irish"
        case australian = "Australian"
        case transatlantic = "Transatlantic"
        var id: String { rawValue }
    }

    @ObservedObject var library: ElevenLabsVoiceLibrary
    let personalityName: String
    let onChoose: (ElevenLabsLibraryVoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = VoicePreviewPlayer()
    @State private var presentation: Presentation
    @State private var accent = Accent.american
    @State private var age: Double
    @State private var pitch: Double
    @State private var texture: Double
    @State private var expressiveness: Double

    init(
        library: ElevenLabsVoiceLibrary,
        personalityName: String,
        traits: PersonalityTraits,
        onChoose: @escaping (ElevenLabsLibraryVoice) -> Void
    ) {
        self.library = library
        self.personalityName = personalityName
        self.onChoose = onChoose
        _presentation = State(initialValue: traits.warmth > 0.72 ? .feminine : traits.energy < 0.35 ? .masculine : .androgynous)
        _age = State(initialValue: 0.35 + (1 - traits.energy) * 0.35)
        _pitch = State(initialValue: 0.35 + traits.energy * 0.35)
        _texture = State(initialValue: 0.25 + traits.humor * 0.5)
        _expressiveness = State(initialValue: 0.25 + max(traits.energy, traits.humor) * 0.6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background
                StarField()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Shape the sound; Rocky writes the voice-design prompt and name. ElevenLabs will make three voices to audition.")
                            .font(.system(size: 13))
                            .foregroundStyle(RockyTheme.mint.opacity(0.72))

                        Picker("Presentation", selection: $presentation) {
                            ForEach(Presentation.allCases) { option in
                                Text(option.rawValue.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Accent", selection: $accent) {
                            ForEach(Accent.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                        .tint(RockyTheme.amberBright)

                        VoiceDesignSlider(title: "Age", low: "young", high: "seasoned", value: $age)
                        VoiceDesignSlider(title: "Pitch", low: "deep", high: "bright", value: $pitch)
                        VoiceDesignSlider(title: "Texture", low: "silky", high: "weathered", value: $texture)
                        VoiceDesignSlider(title: "Expression", low: "restrained", high: "theatrical", value: $expressiveness)

                        VStack(alignment: .leading, spacing: 7) {
                            Text(generatedName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(RockyTheme.mintBright)
                            Text(generatedDescription)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RockyTheme.mint.opacity(0.68))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                            .background(fieldBackground)

                        Button {
                            Task { await library.design(description: generatedDescription) }
                        } label: {
                            Label("Generate three previews", systemImage: "sparkles")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .foregroundStyle(RockyTheme.ink)
                                .background(RoundedRectangle(cornerRadius: 12).fill(RockyTheme.amberBright))
                        }
                        .buttonStyle(.plain)
                        .disabled(library.loading)

                        if library.loading { ProgressView().tint(RockyTheme.amberBright) }
                        ForEach(Array(library.previews.enumerated()), id: \.element.id) { index, preview in
                            HStack {
                                Button {
                                    player.play(preview.audio, id: preview.id)
                                } label: {
                                    Label("Preview \(index + 1)", systemImage: "play.circle.fill")
                                        .foregroundStyle(RockyTheme.mintBright)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button("Use this voice") {
                                    Task {
                                        if let voice = await library.save(
                                            preview: preview,
                                            name: generatedName,
                                            description: generatedDescription
                                        ) { onChoose(voice) }
                                    }
                                }
                                .fontWeight(.semibold)
                                .foregroundStyle(RockyTheme.amberBright)
                            }
                            .padding(14)
                            .background(fieldBackground)
                        }
                        if let error = library.errorMessage {
                            Text(error)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RockyTheme.amberBright)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Create voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(RockyTheme.ink.opacity(0.72))
    }

    private var generatedName: String {
        "\(personalityName) · \(descriptor(pitch, ["Deep", "Grounded", "Clear", "Bright"]))"
    }

    private var generatedDescription: String {
        let ageText = descriptor(age, ["young adult", "adult", "mature", "seasoned older adult"])
        let pitchText = descriptor(pitch, ["deep resonant", "low grounded", "clear mid-register", "light bright"])
        let textureText = descriptor(texture, ["silky clean", "smooth natural", "gently textured", "distinctly weathered"])
        let expressionText = descriptor(expressiveness, ["restrained and precise", "natural and conversational", "animated and playful", "theatrically expressive"])
        return "An original \(ageText) \(presentation.rawValue) voice with a \(accent.rawValue) accent, \(pitchText) pitch, and \(textureText) texture. \(expressionText), intimate, characterful, and suitable for warm real-time conversation. Perfect audio quality."
    }

    private func descriptor(_ value: Double, _ choices: [String]) -> String {
        choices[min(choices.count - 1, Int(value * Double(choices.count)))]
    }
}

private struct VoiceDesignSlider: View {
    let title: String
    let low: String
    let high: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).foregroundStyle(RockyTheme.mintBright)
                Spacer()
                Text("\(Int(value * 100))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RockyTheme.amberBright)
            }
            Slider(value: $value, in: 0...1).tint(RockyTheme.amber)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(RockyTheme.mint.opacity(0.5))
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12).fill(RockyTheme.ink.opacity(0.72)))
    }
}
