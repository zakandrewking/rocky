import SwiftUI

struct PersonalitySelectorView: View {
    @ObservedObject var store: PersonalityStore
    @Binding var selection: String
    let canChange: Bool
    let hasBody: Bool
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
            PersonalityEditorView(
                profile: profile,
                isNew: creatingProfile,
                hasBody: hasBody,
                onSave: { saved in
                    store.save(saved)
                    if creatingProfile || selection == saved.id {
                        selection = saved.id
                        onChange(saved.id)
                    }
                    editorDraft = nil
                },
                onDelete: creatingProfile ? nil : {
                    delete(profile)
                    editorDraft = nil
                }
            )
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
                delete(pendingDelete)
                self.pendingDelete = nil
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
            detail: "Default",
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
            summary: "",
            detail: profile.isGenerated ? "ElevenLabs · \(voiceName)" : "Creation required",
            selected: selection == profile.id,
            editable: true,
            select: {
                if profile.isGenerated {
                    select(profile.id)
                } else {
                    creatingProfile = false
                    editorDraft = profile
                }
            },
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
            .disabled(!profile.isGenerated)
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

    private func delete(_ profile: EditablePersonality) {
        let wasSelected = selection == profile.id
        store.delete(id: profile.id)
        if wasSelected {
            selection = PersonalityCatalog.defaultCharacterID
            onChange(selection)
        }
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
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 14))
                                .foregroundStyle(RockyTheme.mint.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(RockyTheme.amberBright.opacity(0.62))
                        }
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
    let hasBody: Bool
    let onSave: (EditablePersonality) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var identityGenerationState: IdentityGenerationState
    @State private var generationError: String?
    @State private var showingSystemPrompt = false
    @State private var confirmingDelete = false

    init(
        profile: EditablePersonality,
        isNew: Bool,
        hasBody: Bool,
        onSave: @escaping (EditablePersonality) -> Void,
        onDelete: (() -> Void)?
    ) {
        _profile = State(initialValue: profile)
        _identityGenerationState = State(initialValue: profile.isGenerated ? .ready : .initial)
        self.isNew = isNew
        self.hasBody = hasBody
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var isGeneratingIdentity: Bool {
        identityGenerationState == .loading
    }

    private var generationIsCurrent: Bool {
        profile.generationIsCurrent
    }

    private var creationNeedsRefresh: Bool {
        profile.hasGeneratedArtifact && !profile.generationIsCurrent
    }

    private var creationActionTitle: String {
        if creationNeedsRefresh { return "Regenerate from changed sliders" }
        return profile.isGenerated ? "Generate another version" : "Generate character"
    }

    private var creationInstruction: String {
        if creationNeedsRefresh { return "The sliders changed. Generate again before Save so the name and system prompt match these passages." }
        if generationIsCurrent { return "Generation is current. You can preview the exact system prompt, choose a voice, and Save." }
        return "Generation is required before Save. One request turns these seven passages into a name and traditional system prompt."
    }

    private var personalityChoice: PersonalityChoice {
        PersonalityChoice(
            id: profile.id,
            name: profile.name,
            summary: "",
            customPrompt: profile.prompt,
            speech: .elevenLabs(voiceID: profile.voiceID, stability: 0.5, speed: profile.voiceSpeed)
        )
    }

    private var fullSystemPrompt: String {
        OpenAIRealtimeMinter.systemInstructions(
            hasBody: hasBody,
            personality: personalityChoice
        ) ?? profile.prompt ?? "Generate the character before previewing its system prompt."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background
                StarField()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        editorSection(isNew ? "1 · Personality" : "Personality") {
                            Text("Each slider retrieves one kind of source passage. No slider secretly rewrites the other six roles.")
                                .font(.system(size: 12))
                                .foregroundStyle(RockyTheme.mint.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)
                            TraitSlider(title: "Warmth · childhood", low: "guarded", high: "cherished", value: $profile.traits.warmth)
                            TraitSlider(title: "Energy · drive", low: "still", high: "adventurous", value: $profile.traits.energy)
                            TraitSlider(title: "Humor · comic lens", low: "earnest", high: "mischievous", value: $profile.traits.humor)
                            TraitSlider(title: "Curiosity · dream", low: "simple wish", high: "discovery", value: $profile.traits.curiosity)
                            TraitSlider(title: "Talkativeness · voice", low: "terse", high: "expansive", value: $profile.traits.talkativeness)
                            TraitSlider(
                                title: "Earth ↔ Sky · physical form",
                                low: "small creature",
                                middle: "larger creature",
                                high: "space-being",
                                value: $profile.traits.earthToSky
                            )
                            TraitSlider(
                                title: "Fantasy ↔ Reality · origin",
                                low: "fantastical",
                                middle: "myth-touched",
                                high: "real-world",
                                value: $profile.traits.fantasyToReality
                            )
                        }

                        editorSection(isNew ? "2 · Literary DNA" : "Literary DNA") {
                            Text("These seven direct public-domain passages are the complete inputs to one creation pass. Their source metadata is for you; the resulting character receives a conventional authored system prompt.")
                                .font(.system(size: 12))
                                .foregroundStyle(RockyTheme.mint.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                showingSystemPrompt = true
                            } label: {
                                Label("Preview full system prompt", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RockyTheme.amberBright)
                            }
                            .buttonStyle(.plain)
                            .disabled(!generationIsCurrent)
                            .opacity(generationIsCurrent ? 1 : 0.45)

                            Text(generationIsCurrent
                                ? "Shows the generated character plus shared speech, safety, memory, and \(hasBody ? "connected-body" : "voice-only") rules."
                                : "Generate the character in Step 3 before previewing its final prompt.")
                                .font(.system(size: 11))
                                .foregroundStyle(RockyTheme.mint.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(profile.literaryDNA.quotes) { quote in
                                LiteraryQuoteCard(quote: quote)
                            }
                        }

                        editorSection(isNew ? "3 · Generate" : "Generate") {
                            VStack(alignment: .leading, spacing: 8) {
                                if isGeneratingIdentity {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .tint(RockyTheme.amberBright)
                                        Text("Compiling one coherent life…")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(RockyTheme.mintBright)
                                    }
                                    .padding(.vertical, 12)
                                } else if profile.hasGeneratedArtifact {
                                    Text(profile.name)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(RockyTheme.mintBright)
                                    if creationNeedsRefresh {
                                        Text("The sliders changed—generate again before saving.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(RockyTheme.amberBright)
                                    }
                                } else {
                                    Text("Adjust the sliders, inspect their passages, then generate the character.")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(RockyTheme.mintBright)
                                }
                            }
                            .padding(14)
                            .background(fieldBackground)

                            Button {
                                Task { await startGeneratingIdentity() }
                            } label: {
                                Label(
                                    creationActionTitle,
                                    systemImage: "sparkles"
                                )
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RockyTheme.amberBright)
                            }
                            .buttonStyle(.plain)
                            .disabled(isGeneratingIdentity)

                            Text(creationInstruction)
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

                        editorSection(isNew ? "4 · Voice" : "ElevenLabs voice") {
                            NavigationLink {
                                VoiceChooserView(
                                    voiceID: $profile.voiceID,
                                    voiceName: $profile.voiceName
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(RockyTheme.amberBright)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.voiceName ?? ElevenLabsVoiceOption.resolved(profile.voiceID).name)
                                            .foregroundStyle(RockyTheme.mintBright)
                                        Text("Choose an ElevenLabs voice")
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
                                title: "Speaking speed",
                                low: "slow",
                                high: "quick",
                                value: Binding(
                                    get: { (profile.voiceSpeed - 0.7) / 0.5 },
                                    set: { profile.voiceSpeed = 0.7 + $0 * 0.5 }
                                )
                            )
                        }

                        if onDelete != nil {
                            editorSection("Delete") {
                                Button(role: .destructive) {
                                    confirmingDelete = true
                                } label: {
                                    Label("Delete \(profile.name)", systemImage: "trash")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                            }
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
                    .disabled(isGeneratingIdentity || !generationIsCurrent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSystemPrompt) {
            SystemPromptPreviewView(prompt: fullSystemPrompt, hasBody: hasBody)
        }
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the personality from this phone.")
        }
    }

    private func startGeneratingIdentity() async {
        guard !isGeneratingIdentity else { return }
        identityGenerationState = .loading
        await performGeneration()
    }

    private func performGeneration() async {
        identityGenerationState = .loading
        generationError = nil
        let requestedTraits = profile.traits
        do {
            let created = try await PersonalityGenerator.generate(for: requestedTraits)
            profile.name = created.name
            profile.generatedPrompt = created.systemPrompt
            profile.generatedTraits = requestedTraits
            identityGenerationState = .ready
        } catch {
            generationError = "Couldn’t generate that one. The previous valid version, if any, is unchanged. Check the connection and retry."
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

private struct SystemPromptPreviewView: View {
    let prompt: String
    let hasBody: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.background

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(
                            hasBody ? "ROBOT BODY CONNECTED" : "VOICE ONLY · NO ROBOT BODY",
                            systemImage: hasBody ? "sensor.fill" : "waveform"
                        )
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(RockyTheme.amberBright)

                        Text("This is the exact instructions field sent to OpenAI Realtime for the current draft. Tool schemas are separate session fields.")
                            .font(.system(size: 12))
                            .foregroundStyle(RockyTheme.mint.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(prompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RockyTheme.mintBright)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(RockyTheme.ink.opacity(0.76))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(RockyTheme.mint.opacity(0.14), lineWidth: 1)
                                    }
                            }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Full system prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(RockyTheme.ink.opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: prompt) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .foregroundStyle(RockyTheme.amberBright)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RockyTheme.amberBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct LiteraryQuoteCard: View {
    let quote: LiteraryQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(quote.slot.rawValue) · \(quote.slot.sliderName)".uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RockyTheme.amberBright)

                Spacer()

                if let sourceURL = quote.sourceURL {
                    Link(destination: sourceURL) {
                        Label("SOURCE", systemImage: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RockyTheme.mint.opacity(0.68))
                    }
                    .accessibilityLabel("Open \(quote.work) by \(quote.author) on Project Gutenberg")
                }
            }

            Text("“\(quote.text)”")
                .font(.system(size: 14, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(RockyTheme.mintBright)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(quote.author) · \(quote.work)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RockyTheme.mint.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(RockyTheme.ink.opacity(0.64))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(RockyTheme.mint.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

private struct TraitSlider: View {
    let title: String
    let low: String
    let middle: String?
    let high: String
    @Binding var value: Double

    init(
        title: String,
        low: String,
        middle: String? = nil,
        high: String,
        value: Binding<Double>
    ) {
        self.title = title
        self.low = low
        self.middle = middle
        self.high = high
        _value = value
    }

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
                if let middle {
                    Text(middle)
                    Spacer()
                }
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
        hasBody: false,
        onChange: { _ in }
    )
}
