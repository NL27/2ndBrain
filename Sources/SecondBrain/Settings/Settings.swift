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
        static let followMouseWhileRecording = "followMouseWhileRecording"
        static let showInputOverlay = "showInputOverlay"
        static let showMouseRing = "showMouseRing"
        static let showLiveCaptions = "showLiveCaptions"
        static let ocrLanguageCorrection = "ocrLanguageCorrection"
        static let dismissedDisplayHint = "dismissedDisplayHint"
        static let whisperModel = "whisperModel"
        static let whisperBackend = "whisperBackend"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let tironMaxSpeakers = "tironMaxSpeakers"
        static let heedBaseURL = "heedBaseURL"
        static let refineLiveWithTiron = "refineLiveWithTiron"
        static let setupCompletedVersion = "setupCompletedVersion"
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
            Keys.followMouseWhileRecording: false,
            Keys.showInputOverlay: false,
            Keys.showMouseRing: false,
            Keys.showLiveCaptions: true,
            Keys.ocrLanguageCorrection: false,
            Keys.whisperModel: "base.en",
            Keys.whisperBackend: TranscriptionBackend.whisperCpp.rawValue,
            Keys.transcriptionLanguage: "auto",
            Keys.tironMaxSpeakers: 0,
            Keys.heedBaseURL: "http://localhost:5170",
            Keys.refineLiveWithTiron: true,
            Keys.aiProvider: AIProvider.localOpenAICompatible.rawValue,
            Keys.aiBaseURL: "http://localhost:8000/v1",
            Keys.aiModel: "llama3.2",
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

    /// Records a zoomed crop that pans to keep the pointer centred.
    var followMouseWhileRecording: Bool {
        get { defaults.bool(forKey: Keys.followMouseWhileRecording) }
        set { defaults.set(newValue, forKey: Keys.followMouseWhileRecording) }
    }

    /// Draws click ripples and pressed keys on screen so they land in the video.
    var showInputOverlay: Bool {
        get { defaults.bool(forKey: Keys.showInputOverlay) }
        set { defaults.set(newValue, forKey: Keys.showInputOverlay) }
    }

    /// Keeps a coloured ring around the pointer so it's easy to follow.
    var showMouseRing: Bool {
        get { defaults.bool(forKey: Keys.showMouseRing) }
        set { defaults.set(newValue, forKey: Keys.showMouseRing) }
    }

    /// Whether the live transcript panel is displayed; the transcript is saved
    /// either way.
    var showLiveCaptions: Bool {
        get { defaults.bool(forKey: Keys.showLiveCaptions) }
        set { defaults.set(newValue, forKey: Keys.showLiveCaptions) }
    }

    /// Lets Vision rewrite results towards dictionary words. Off keeps OCR
    /// literal, which matters for code, IDs and punctuation.
    var ocrLanguageCorrection: Bool {
        get { defaults.bool(forKey: Keys.ocrLanguageCorrection) }
        set { defaults.set(newValue, forKey: Keys.ocrLanguageCorrection) }
    }

    /// Display mode the non-Retina capture-quality hint was already shown for.
    var dismissedDisplayHint: String? {
        get { defaults.string(forKey: Keys.dismissedDisplayHint) }
        set { defaults.set(newValue, forKey: Keys.dismissedDisplayHint) }
    }

    var whisperModel: String {
        get { defaults.string(forKey: Keys.whisperModel) ?? "base.en" }
        set { defaults.set(newValue, forKey: Keys.whisperModel) }
    }

    var whisperBackend: TranscriptionBackend {
        get { TranscriptionBackend(rawValue: defaults.string(forKey: Keys.whisperBackend) ?? "") ?? .whisperCpp }
        set { defaults.set(newValue.rawValue, forKey: Keys.whisperBackend) }
    }

    /// Language passed to the transcription engines; "auto" lets them detect it.
    var transcriptionLanguage: String {
        get { defaults.string(forKey: Keys.transcriptionLanguage) ?? "auto" }
        set { defaults.set(newValue, forKey: Keys.transcriptionLanguage) }
    }

    /// Upper bound on speakers Tiron may attribute; 0 lets it decide (max 8).
    var tironMaxSpeakers: Int {
        get { defaults.integer(forKey: Keys.tironMaxSpeakers) }
        set { defaults.set(newValue, forKey: Keys.tironMaxSpeakers) }
    }

    /// Where the local heed server is listening for live transcription.
    var heedBaseURL: String {
        get { defaults.string(forKey: Keys.heedBaseURL) ?? "http://localhost:5170" }
        set { defaults.set(newValue, forKey: Keys.heedBaseURL) }
    }

    /// After a live session with more than one voice, re-run the recording
    /// through Tiron for its stronger speaker attribution.
    var refineLiveWithTiron: Bool {
        get { defaults.bool(forKey: Keys.refineLiveWithTiron) }
        set { defaults.set(newValue, forKey: Keys.refineLiveWithTiron) }
    }

    /// App version that finished first-run setup; nil means it never ran.
    var setupCompletedVersion: String? {
        get { defaults.string(forKey: Keys.setupCompletedVersion) }
        set { defaults.set(newValue, forKey: Keys.setupCompletedVersion) }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "") ?? .localOpenAICompatible }
        set { defaults.set(newValue.rawValue, forKey: Keys.aiProvider) }
    }

    var aiBaseURL: String {
        get { defaults.string(forKey: Keys.aiBaseURL) ?? "http://localhost:8000/v1" }
        set { defaults.set(newValue, forKey: Keys.aiBaseURL) }
    }

    var aiModel: String {
        get { defaults.string(forKey: Keys.aiModel) ?? "llama3.2" }
        set { defaults.set(newValue, forKey: Keys.aiModel) }
    }

    var lastSystemSignature: String? {
        get { defaults.string(forKey: Keys.lastSystemSignature) }
        set { defaults.set(newValue, forKey: Keys.lastSystemSignature) }
    }
}
