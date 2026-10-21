import SwiftUI

/// Minimal TOML colorizer for the read-only generated-config preview.
///
/// It highlights the three token kinds the generated file actually contains —
/// comments, table headers and strings (including `'''` literal blocks) — and
/// leaves everything else in the default ink.
package enum TOMLHighlighter {
    private static let comment = Color(hex: 0x5D6B64)
    private static let table = RouterTheme.accent
    private static let string = Color(hex: 0xB9D6C7)

    package static func highlight(_ toml: String, font: Font) -> AttributedString {
        var output = AttributedString()
        var insideLiteralBlock = false

        for line in toml.components(separatedBy: "\n") {
            output.append(styled(line: line, insideLiteralBlock: &insideLiteralBlock, font: font))
            output.append(plain("\n", font: font))
        }
        return output
    }

    private static func styled(
        line: String,
        insideLiteralBlock: inout Bool,
        font: Font
    ) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let literalDelimiters = line.ranges(of: "'''").count

        if insideLiteralBlock {
            if literalDelimiters > 0 { insideLiteralBlock = false }
            return colored(line, string, font: font)
        }
        if literalDelimiters == 1 {
            insideLiteralBlock = true
            return colored(line, string, font: font)
        }
        if trimmed.hasPrefix("#") {
            return colored(line, comment, font: font)
        }
        if trimmed.hasPrefix("[") {
            return colored(line, table, font: font)
        }
        return quotedStrings(in: line, font: font)
    }

    /// Colors every double-quoted run on a `key = "value"` line.
    private static func quotedStrings(in line: String, font: Font) -> AttributedString {
        var output = AttributedString()
        var pending = ""
        var insideQuotes = false

        for character in line {
            if character == "\"" {
                if insideQuotes {
                    pending.append(character)
                    output.append(colored(pending, string, font: font))
                    pending = ""
                    insideQuotes = false
                } else {
                    output.append(plain(pending, font: font))
                    pending = String(character)
                    insideQuotes = true
                }
                continue
            }
            pending.append(character)
        }

        output.append(insideQuotes ? colored(pending, string, font: font) : plain(pending, font: font))
        return output
    }

    private static func plain(_ text: String, font: Font) -> AttributedString {
        colored(text, RouterTheme.ink2, font: font)
    }

    private static func colored(_ text: String, _ color: Color, font: Font) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = color
        piece.font = font
        return piece
    }
}
