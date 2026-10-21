import Foundation

/// Removes request content and credential-like values before subprocess output
/// can be retained in memory or shown in the UI.
package enum DiagnosticRedactor {
    package static let placeholder = "<redacted>"
    package static let requestContentPlaceholder =
        "<redacted: diagnostic contained request or source content>"

    /// Keys whose value may carry the user's request or their source.
    ///
    /// Two of them are deliberately narrower than they look, because both names
    /// are also what an upstream calls the parts of its own rejection, and a
    /// rejection stripped of its reason and its error code is the one line that
    /// would have explained the failure. `messages` is plural on purpose: a
    /// singular `message` is the error text. Source is matched as `source_code`
    /// rather than a bare `code`. What either could still wrap — a request
    /// payload, a listing — names its own carrier, `content`, on the same line.
    private static let requestContentPattern = try! NSRegularExpression(
        pattern: #"(?i)"?(?:prompt|prompts|messages|request[_-]?body|response[_-]?body|input|source(?:[_-]?code)?|file[_-]?contents?|contents?|body)"?\s*[:=]"#
    )

    private static let replacements: [(NSRegularExpression, String)] = [
        (
            try! NSRegularExpression(
                pattern: #"(?im)^(\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[-_]?key)\s*:\s*).*$"#
            ),
            "$1\(placeholder)"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password)\b(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\r\n,;}\]]+)"#
            ),
            "$1$2\(placeholder)"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b([A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD))(\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)"#
            ),
            "$1$2\(placeholder)"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#
            ),
            "Bearer \(placeholder)"
        ),
        (
            try! NSRegularExpression(
                pattern: #"\b(?:sk|rk|pk|api)[-_][A-Za-z0-9][A-Za-z0-9_-]{7,}\b"#
            ),
            placeholder
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9_-]{40,}(?![A-Za-z0-9])"#
            ),
            placeholder
        ),
    ]

    package static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        let fullRange = NSRange(text.startIndex..., in: text)
        if requestContentPattern.firstMatch(in: text, range: fullRange) != nil {
            return requestContentPlaceholder
        }

        return replacements.reduce(text) { result, replacement in
            let range = NSRange(result.startIndex..., in: result)
            return replacement.0.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement.1
            )
        }
    }
}
