import AVFoundation
import Foundation

struct ElevenLabsLibraryVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let previewURL: URL?
}

struct ElevenLabsVoicePreview: Identifiable, Equatable, Sendable {
    let id: String
    let audio: Data
}

/// The small account-facing part of ElevenLabs: list voices, design three candidates, then save
/// only the candidate the user chooses. The API key stays in the generated Info.plist and is
/// never persisted alongside a personality.
@MainActor
final class ElevenLabsVoiceLibrary: ObservableObject {
    @Published private(set) var voices: [ElevenLabsLibraryVoice] = []
    @Published private(set) var previews: [ElevenLabsVoicePreview] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?

    private struct VoiceList: Decodable {
        struct Voice: Decodable {
            let voiceID: String
            let name: String
            let description: String?
            let category: String?
            let previewURL: URL?

            enum CodingKeys: String, CodingKey {
                case voiceID = "voice_id"
                case name, description, category
                case previewURL = "preview_url"
            }
        }
        let voices: [Voice]
    }

    private struct DesignResponse: Decodable {
        struct Preview: Decodable {
            let audioBase64: String
            let generatedVoiceID: String

            enum CodingKeys: String, CodingKey {
                case audioBase64 = "audio_base_64"
                case generatedVoiceID = "generated_voice_id"
            }
        }
        let previews: [Preview]
    }

    private struct CreatedVoice: Decodable {
        let voiceID: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case name
        }
    }

    var isConfigured: Bool { apiKey != nil }

    func loadVoices() async {
        guard voices.isEmpty, !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
            components.queryItems = [
                .init(name: "page_size", value: "100"),
                .init(name: "sort", value: "name"),
                .init(name: "sort_direction", value: "asc"),
                .init(name: "include_total_count", value: "false"),
            ]
            let data = try await perform(url: components.url!)
            let response = try JSONDecoder().decode(VoiceList.self, from: data)
            voices = response.voices.map {
                ElevenLabsLibraryVoice(
                    id: $0.voiceID,
                    name: $0.name,
                    summary: $0.description ?? $0.category ?? "ElevenLabs voice",
                    previewURL: $0.previewURL
                )
            }
        } catch {
            let message = error.localizedDescription
            errorMessage = message.contains("voices_read")
                ? "Account voices are hidden by this ElevenLabs key. Enable voices_read to show them; Comet, Pip, and Rumble still work."
                : "Could not load account voices. Comet, Pip, and Rumble are still available."
        }
    }

    func design(description: String) async {
        loading = true
        errorMessage = nil
        previews = []
        defer { loading = false }
        do {
            let body: [String: Any] = [
                "voice_description": description,
                "model_id": "eleven_multilingual_ttv_v2",
                "auto_generate_text": true,
                "guidance_scale": 5,
            ]
            let data = try await perform(
                url: URL(string: "https://api.elevenlabs.io/v1/text-to-voice/design")!,
                method: "POST",
                body: body
            )
            let response = try JSONDecoder().decode(DesignResponse.self, from: data)
            previews = response.previews.compactMap { preview in
                guard let audio = Data(base64Encoded: preview.audioBase64) else { return nil }
                return ElevenLabsVoicePreview(id: preview.generatedVoiceID, audio: audio)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(preview: ElevenLabsVoicePreview, name: String, description: String) async -> ElevenLabsLibraryVoice? {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let data = try await perform(
                url: URL(string: "https://api.elevenlabs.io/v1/text-to-voice")!,
                method: "POST",
                body: [
                    "voice_name": name,
                    "voice_description": description,
                    "generated_voice_id": preview.id,
                    "labels": ["use_case": "rocky-personality"],
                ]
            )
            let created = try JSONDecoder().decode(CreatedVoice.self, from: data)
            let voice = ElevenLabsLibraryVoice(
                id: created.voiceID,
                name: created.name,
                summary: description,
                previewURL: nil
            )
            voices.append(voice)
            return voice
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func preview(_ voice: ElevenLabsLibraryVoice) async -> Data? {
        guard let previewURL = voice.previewURL else { return nil }
        do { return try await perform(url: previewURL, authenticated: false) }
        catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private var apiKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RockyElevenLabsKey") as? String) ?? ""
        return key.isEmpty ? nil : key
    }

    private func perform(
        url: URL,
        method: String = "GET",
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if authenticated {
            guard let apiKey else {
                throw RockyError.commandFailed("ElevenLabs is not configured in this build")
            }
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(decoding: data, as: UTF8.self).prefix(240)
            throw RockyError.commandFailed("ElevenLabs request failed (\(status)): \(message)")
        }
        return data
    }
}

@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func play(_ data: Data, id: String) {
        player?.stop()
        player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        player?.play()
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}
