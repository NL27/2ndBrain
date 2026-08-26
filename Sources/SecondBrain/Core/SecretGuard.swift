import Foundation

/// Conservative detectors for credentials that must not land in the vault,
/// clipboard history, overnight queue, or agent logs. False positives are
/// acceptable; missing a live token is not.
enum SecretGuard {
    struct Hit: Sendable {
        let kind: String
    }

    static func firstHit(in text: String) -> Hit? {
        let sample = String(text.prefix(20_000))
        for (kind, pattern) in patterns {
            if pattern.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil {
                return Hit(kind: kind)
            }
        }
        return nil
    }

    static func looksSecret(_ text: String) -> Bool { firstHit(in: text) != nil }

    private static let patterns: [(String, NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("openai-key", #"sk-[A-Za-z0-9_-]{16,}"#),
            ("openrouter-key", #"sk-or-[A-Za-z0-9_-]{16,}"#),
            ("anthropic-key", #"sk-ant-[A-Za-z0-9_-]{16,}"#),
            ("github-pat", #"ghp_[A-Za-z0-9]{20,}"#),
            ("github-fine-grained", #"github_pat_[A-Za-z0-9_]{20,}"#),
            ("huggingface-token", #"hf_[A-Za-z0-9]{20,}"#),
            ("slack-token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
            ("aws-access-key", #"AKIA[0-9A-Z]{16}"#),
            ("jwt", #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+"#),
            ("bearer-jwt", #"(?i)bearer\s+eyJ[A-Za-z0-9._-]+"#),
            ("private-key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#),
            ("n8n-env-token", #"(?i)N8N_[A-Z0-9_]*TOKEN\s*=\s*\S{24,}"#),
        ]
        return raw.compactMap { kind, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (kind, regex)
        }
    }()
}
