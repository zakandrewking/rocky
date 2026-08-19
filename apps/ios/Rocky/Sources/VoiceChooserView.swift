import SwiftUI

struct VoiceChooserView: View {
    @Binding var voiceID: String
    @Binding var voiceName: String?

    @StateObject private var library = ElevenLabsVoiceLibrary()
    @StateObject private var player = VoicePreviewPlayer()

    var body: some View {
        ZStack {
            RockyTheme.background
            StarField()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
