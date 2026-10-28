import Foundation

enum TextCleanup {
    /// Limite per singola nota/titolo, per non mandare messaggi enormi via Bluetooth.
    static let maxLength = 20_000

    /// PowerPoint separa i paragrafi con \r e gli a capo manuali con \u{0B}: li uniformiamo a \n.
    static func normalize(_ text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0B}", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let trimmed = unified.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return String(trimmed.prefix(maxLength))
    }
}
