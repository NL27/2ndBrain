import Foundation

enum AIProvider: String, CaseIterable {
    case localOpenAICompatible   // Ollama / LM Studio / llama.cpp server, etc.
    case openAI
    case anthropic

    var displayName: String {
        switch self {
        case .localOpenAICompatible: return "Local (OpenAI-compatible)"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var requiresAPIKey: Bool { self != .localOpenAICompatible }
}

struct ChatMessage {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

/// Talks to local or cloud AI agents over HTTP. Local providers (Ollama,
/// LM Studio, llama.cpp) use the OpenAI-compatible endpoint; cloud providers
/// use their native APIs. API keys are stored in the Keychain.
final class AIConnector {
    static let shared = AIConnector()
    private init() {}

    enum AIError: LocalizedError {
        case missingAPIKey, badResponse(String), badURL
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No API key set for this provider (set it in the menu)."
            case .badResponse(let s): return "AI request failed: \(s)"
            case .badURL: return "Invalid AI base URL."
            }
        }
    }

    func complete(messages: [ChatMessage]) async throws -> String {
        switch Settings.shared.aiProvider {
        case .localOpenAICompatible:
            return try await openAICompatible(baseURL: Settings.shared.aiBaseURL, apiKey: nil, messages: messages)
        case .openAI:
            let key = try requireKey()
            return try await openAICompatible(baseURL: "https://api.openai.com/v1", apiKey: key, messages: messages)
        case .anthropic:
            let key = try requireKey()
            return try await anthropic(apiKey: key, messages: messages)
        }
    }

    private func requireKey() throws -> String {
        guard let key = Keychain.get(account: Settings.shared.aiProvider.rawValue), !key.isEmpty else {
            throw AIError.missingAPIKey
        }
        return key
    }

    // MARK: - OpenAI-compatible (cloud OpenAI + local servers)

    private func openAICompatible(baseURL: String, apiKey: String?, messages: [ChatMessage]) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/chat/completions") else {
            throw AIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let choices = json?["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        throw AIError.badResponse(String(data: data, encoding: .utf8) ?? "unknown")
    }

    // MARK: - Anthropic

    private func anthropic(apiKey: String, messages: [ChatMessage]) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let system = messages.first { $0.role == "system" }?.content
        let convo = messages.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "max_tokens": 1024,
            "messages": convo
        ]
        if let system { body["system"] = system }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let content = json?["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String {
            return text
        }
        throw AIError.badResponse(String(data: data, encoding: .utf8) ?? "unknown")
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.badResponse("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
    }
}

/// Minimal Keychain wrapper for storing AI API keys.
enum Keychain {
    private static let service = "com.dao.secondbrain.ai"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
