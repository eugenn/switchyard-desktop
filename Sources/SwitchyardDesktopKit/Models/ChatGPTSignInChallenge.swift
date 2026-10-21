import Foundation

/// The device challenge printed by the pinned, bundled LiteLLM authenticator.
/// Keep it in memory only; it must not be included in diagnostics or saved setup.
package struct ChatGPTSignInChallenge: Equatable {
    package let url: URL
    package let code: String

    package init?(message: String) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let url = detector.matches(in: message, range: NSRange(message.startIndex..., in: message))
                .compactMap(\.url).first(where: {
                    $0.scheme == "https" && $0.host == "auth.openai.com"
                        && $0.path == "/codex/device" && $0.user == nil && $0.password == nil
                        && $0.port == nil && $0.query == nil && $0.fragment == nil
                }),
              let pattern = try? NSRegularExpression(pattern: #"(?m)^2\) Enter code: ([A-Z0-9][A-Z0-9-]{3,31})\r?\n"#),
              let match = pattern.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        self.url = url
        self.code = String(message[range])
    }
}

/// Pipe reads may split a URL, a device code, or even a UTF-8 character.
package struct ChatGPTSignInOutput {
    private var bytes = Data()
    package static let limit = 16_384
    package var message: String { String(decoding: bytes, as: UTF8.self) }

    package mutating func append(_ data: Data) {
        bytes.append(data.prefix(max(0, Self.limit - bytes.count)))
    }
}
