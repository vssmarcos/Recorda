import Foundation
import CryptoKit

// MARK: - Relógio

/// Fonte de tempo injetável: o domínio nunca chama `Date()` diretamente.
public struct SchedClock: Sendable {
    public var now: @Sendable () -> Date
    public var timeZone: @Sendable () -> TimeZone

    public init(now: @escaping @Sendable () -> Date = { Date() },
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.now = now
        self.timeZone = timeZone
    }

    public static let system = SchedClock()
}

/// Relógio controlável para testes.
public final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public let zone: TimeZone

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), zone: TimeZone = TimeZone(identifier: "UTC")!) {
        self.current = start
        self.zone = zone
    }

    public var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    public func advance(seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }

    public func advance(days: Double) { advance(seconds: days * 86_400) }

    public var clock: SchedClock {
        SchedClock(now: { [self] in self.now }, timeZone: { [zone] in zone })
    }
}

// MARK: - Hash e identificadores

public enum Hashing {
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1Hex(_ string: String) -> String { sha1Hex(Data(string.utf8)) }

    /// Checksum do primeiro campo, como no Anki: 8 primeiros dígitos hex do SHA-1 do texto sem HTML.
    public static func fieldChecksum(_ field: String) -> Int64 {
        let stripped = HTMLText.stripPreservingMedia(field)
        let hex = sha1Hex(stripped)
        return Int64(hex.prefix(8), radix: 16) ?? 0
    }
}

public enum GUID {
    private static let table = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")

    /// GUID de nota: 64 bits aleatórios em base 91.
    public static func make() -> String {
        var value = UInt64.random(in: UInt64.min...UInt64.max)
        if value == 0 { return String(table[0]) }
        var out: [Character] = []
        let base = UInt64(table.count)
        while value > 0 {
            out.append(table[Int(value % base)])
            value /= base
        }
        return String(out.reversed())
    }
}

// MARK: - Texto / HTML

public enum HTMLText {
    private static let tagRegex = try! NSRegularExpression(pattern: "(?si)<!--.*?-->|<style.*?>.*?</style>|<script.*?>.*?</script>|<[^>]*>")
    private static let mediaRegex = try! NSRegularExpression(pattern: "(?i)<img[^>]+src=[\"']?([^\"'>]+)[\"']?[^>]*>")
    private static let soundRegex = try! NSRegularExpression(pattern: "\\[sound:([^\\]]+)\\]")
    private static let breakRegex = try! NSRegularExpression(pattern: "(?i)<br\\s*/?>|</?(?:div|p|li|tr|h[1-6])(?:\\s[^>]*)?>")
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»",
        "copy": "©", "reg": "®", "deg": "°", "times": "×", "divide": "÷",
        "rarr": "→", "larr": "←", "euro": "€", "pound": "£",
    ]

    static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in entityRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else if body.hasPrefix("#") {
                if let code = UInt32(body.dropFirst(1)), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else {
                replacement = namedEntities[body]
            }
            result += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Remove todas as tags e decodifica entidades.
    public static func strip(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        let noTags = replace(tagRegex, in: html, with: "")
        return decodeEntities(noTags)
    }

    /// Como `strip`, mas quebras de bloco viram espaço (para exibição em listas).
    public static func stripToLine(_ html: String) -> String {
        var text = replace(breakRegex, in: html, with: " ")
        text = replace(soundRegex, in: text, with: "")
        text = strip(text)
        text = text.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove HTML, mas mantém o nome dos arquivos de imagem (para que notas só com mídia tenham checksum distinto).
    public static func stripPreservingMedia(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        let withMedia = replace(mediaRegex, in: html, with: " $1 ")
        return strip(withMedia)
    }

    /// Nomes de arquivos de mídia referenciados em um texto de campo.
    public static func mediaReferences(in text: String) -> [String] {
        var names: [String] = []
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in soundRegex.matches(in: text, range: range) {
            names.append(ns.substring(with: match.range(at: 1)))
        }
        let generic = try! NSRegularExpression(pattern: "(?i)<(?:img|audio|video|source|object)[^>]+(?:src|data)=(?:\"([^\"]+)\"|'([^']+)'|([^ >]+))")
        for match in generic.matches(in: text, range: range) {
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let raw = ns.substring(with: match.range(at: group))
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("data:") { continue }
                names.append(decodeEntities(raw.removingPercentEncoding ?? raw))
            }
        }
        return names
    }

    /// Remove diacríticos (para a busca `nc:`).
    public static func withoutCombining(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive], locale: nil)
    }
}

extension String {
    /// Normalização NFC, usada em nomes de mídia e campos.
    public var nfc: String { precomposedStringWithCanonicalMapping }
}
