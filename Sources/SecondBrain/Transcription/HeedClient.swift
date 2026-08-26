import Foundation

/// Client for a locally running heed server (github.com/isjunrod/heed), which
/// powers live transcription. heed captures the microphone and system audio on
/// separate channels, runs Parakeet + diarization on the Apple Neural Engine,
/// and streams speaker-labelled text back over Server-Sent Events while the
/// meeting is still going.
final class HeedClient {
    static let shared = HeedClient()
    private init() {}

    /// A live stream has no natural end while a meeting runs, so it must not be
    /// cut short by the default request timeout.
    private let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 0
        return URLSession(configuration: config)
    }()

    struct Health {
        let languageCodes: [String]
        let supportsAutoLanguage: Bool
    }

    struct Turn {
        let speaker: String
        let channel: String
        let text: String
        let start: Double?
    }

    struct StopResult {
        let audioPath: String?
        let turns: [Turn]
    }

    struct LiveLine {
        let id: Int?
        let speaker: String
        let channel: String
        let text: String
    }

    /// heed emits three live shapes depending on which engine is active, and
    /// each one implies different on-screen behaviour.
    enum LiveUpdate {
        case append(LiveLine)   // chunk mode: one finished chunk of audio
        case replace(LiveLine)  // full mode: the whole transcript, re-decoded
        case upsert(LiveLine)   // stream mode: a turn revised in place, by id
    }

    enum LiveEvent {
        case update(LiveUpdate)
        case stopped
        case failed(String)
    }

    // MARK: - Session control

    /// Whether a heed server is answering, plus the languages its engine takes.
    func health() async throws -> Health {
        var request = URLRequest(url: try url("/api/health"))
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("heed is not responding at \(Settings.shared.heedBaseURL)")
        }
        let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
        return Health(languageCodes: payload.languages?.codes ?? [],
                      supportsAutoLanguage: payload.languages?.supportsAuto ?? true)
    }

    /// Mirrors heed's own language resolution: fall back to a supported code
    /// when the active engine can't auto-detect, rather than streaming nothing.
    func resolveLanguage(_ requested: String, health: Health?) -> String {
        guard let health, !health.languageCodes.isEmpty else { return requested }
        let fallback = health.languageCodes.contains("en") ? "en" : health.languageCodes[0]
        if requested == "auto" { return health.supportsAutoLanguage ? "auto" : fallback }
        return health.languageCodes.contains(requested) ? requested : fallback
    }

    /// Starts heed's recorder. Returns false when heed still needs Screen
    /// Recording permission — it opens System Settings itself and starts nothing.
    func startRecording(mode: String = "both") async throws -> Bool {
        let data = try await post("/api/sysrecord/start", body: ["mode": mode], timeout: 30)
        let payload = try? JSONDecoder().decode(StartPayload.self, from: data)
        if let error = payload?.error { throw err(error) }
        return payload?.permissionNeeded != true
    }

    /// Stops recording. heed then re-transcribes the whole take at higher
    /// accuracy with real timestamps, so this can take a while on long meetings.
    func stopRecording(language: String) async throws -> StopResult {
        let data = try await post("/api/sysrecord/stop", body: ["language": language], timeout: 900)
        let payload = try JSONDecoder().decode(StopPayload.self, from: data)
        if let error = payload.error { throw err(error) }
        let turns = (payload.turns ?? []).map {
            Turn(speaker: $0.speaker ?? "Speaker", channel: $0.channel ?? "",
                 text: $0.text ?? "", start: $0.start)
        }
        return StopResult(audioPath: payload.path, turns: turns)
    }

    /// Streams live events for the recording heed currently has open. Finishes
    /// when heed stops recording, or when the consuming task is cancelled.
    func liveEvents(language: String) -> AsyncThrowingStream<LiveEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let encoded = language.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "en"
                    var request = URLRequest(url: try url("/api/sysrecord/live?lang=\(encoded)"))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, _) = try await streamSession.bytes(for: request)

                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            guard let decoded = Self.event(named: event, json: Data(json.utf8)) else { continue }
                            continuation.yield(decoded)
                            switch decoded {
                            case .stopped, .failed: continuation.finish(); return
                            case .update: break
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Wire format

    private static func event(named name: String, json: Data) -> LiveEvent? {
        guard let payload = try? JSONDecoder().decode(EventPayload.self, from: json) else { return nil }
        switch name {
        case "segment": return payload.line.map { .update(.append($0)) }
        case "live": return payload.line.map { .update(.replace($0)) }
        case "turn": return payload.line.map { .update(.upsert($0)) }
        case "stopped": return .stopped
        case "error": return .failed(payload.message ?? "heed stopped transcribing")
        default: return nil  // heartbeat, quality
        }
    }

    private struct EventPayload: Decodable {
        let id: Int?
        let speaker: String?
        let channel: String?
        let text: String?
        let message: String?

        var line: LiveLine? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return LiveLine(id: id, speaker: speaker ?? "Speaker", channel: channel ?? "", text: text)
        }
    }

    private struct HealthPayload: Decodable {
        struct Languages: Decodable {
            let codes: [String]?
            let supportsAuto: Bool?

            enum CodingKeys: String, CodingKey {
                case codes
                case supportsAuto = "supports_auto"
            }
        }
        let languages: Languages?
    }

    private struct StartPayload: Decodable {
        let permissionNeeded: Bool?
        let error: String?
    }

    private struct StopPayload: Decodable {
        struct Turn: Decodable {
            let speaker: String?
            let channel: String?
            let text: String?
            let start: Double?
        }
        let path: String?
        let turns: [Turn]?
        let error: String?
    }

    // MARK: - Helpers

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: Settings.shared.heedBaseURL),
              let resolved = URL(string: path, relativeTo: base) else {
            throw err("Invalid heed address: \(Settings.shared.heedBaseURL)")
        }
        return resolved
    }

    private func post(_ path: String, body: [String: String], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "SecondBrain.Heed", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
