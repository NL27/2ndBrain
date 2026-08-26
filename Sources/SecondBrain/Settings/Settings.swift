import Foundation

/// Persistent user preferences backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let clipboardHistoryLimit = "clipboardHistoryLimit"
        static let captureSystemAudio = "captureSystemAudio"
        static let captureMicrophone = "captureMicrophone"
        static let autoTranscribe = "autoTranscribe"
        static let enableDiarization = "enableDiarization"
        static let whisperModel = "whisperModel"
        static let whisperBackend = "whisperBackend"
        static let aiProvider = "aiProvider"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let lastSystemSignature = "lastSystemSignature"
    }

    private init() {
        defaults.register(defaults: [
            Keys.clipboardHistoryLimit: 200,
            Keys.captureSystemAudio: true,
            Keys.captureMicrophone: true,
            Keys.autoTranscribe: true,
            Keys.enableDiarization: false,
            Keys.whisperModel: "base.en",
            Keys.whisperBackend: TranscriptionBackend.whisperCpp.rawValue,
            Keys.aiProvider: AIProvider.localOpenAICompatible.rawValue,
            Keys.aiBaseURL: "http://localhost:11434/v1",
            Keys.aiModel: "llama3.1"
        ])
    }

    var clipboardHistoryLimit: Int {
        get { defaults.integer(forKey: Keys.clipboardHistoryLimit) }
        set { defaults.set(newValue, forKey: Keys.clipboardHistoryLimit) }
    }

    var captureSystemAudio: Bool {
        get { defaults.bool(forKey: Keys.captureSystemAudio) }
        set { defaults.set(newValue, forKey: Keys.captureSystemAudio) }
    }

    var captureMicrophone: Bool {
        get { defaults.bool(forKey: Keys.captureMicrophone) }
        set { defaults.set(newValue, forKey: Keys.captureMicrophone) }
    }

    var autoTranscribe: Bool {
        get { defaults.bool(forKey: Keys.autoTranscribe) }
        set { defaults.set(newValue, forKey: Keys.autoTranscribe) }
    }

    var enableDiarization: Bool {
        get { defaults.bool(forKey: Keys.enableDiarization) }
        set { defaults.set(newValue, forKey: Keys.enableDiarization) }
    }

    var whisperModel: String {
        get { defaults.string(forKey: Keys.whisperModel) ?? "base.en" }
        set { defaults.set(newValue, forKey: Keys.whisperModel) }
    }

    var whisperBackend: TranscriptionBackend {
        get { TranscriptionBackend(rawValue: defaults.string(forKey: Keys.whisperBackend) ?? "") ?? .whisperCpp }
        set { defaults.set(newValue.rawValue, forKey: Keys.whisperBackend) }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .localOpenAICompatible }
        set { defaults.set(newValue.rawValue, forKey: Keys.aiProvider) }
    }

    var aiBaseURL: String {
        get { defaults.string(forKey: Keys.aiBaseURL) ?? "http://localhost:11434/v1" }
        set { defaults.set(newValue, forKey: Keys.aiBaseURL) }
    }

    var aiModel: String {
        get { defaults.string(forKey: Keys.aiModel) ?? "llama3.1" }
        set { defaults.set(newValue, forKey: Keys.aiModel) }
    }

    var lastSystemSignature: String? {
        get { defaults.string(forKey: Keys.lastSystemSignature) }
        set { defaults.set(newValue, forKey: Keys.lastSystemSignature) }
    }
}
