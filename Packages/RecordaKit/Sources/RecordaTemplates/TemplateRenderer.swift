import Foundation

/// Dados necessários para renderizar um lado de um card.
public struct RenderContext: Sendable {
    /// Nome do campo → conteúdo (HTML).
    public var fields: [String: String]
    /// Índice do card (0-based). Para cloze, o número da omissão é `cardOrdinal + 1`.
    public var cardOrdinal: Int
    public var isAnswer: Bool
    /// Frente já renderizada (para `{{FrontSide}}`).
    public var frontSide: String?
    public var tags: String
    public var deckName: String
    public var cardName: String
    public var notetypeName: String
    public var flag: Int
    public var cardID: Int64

    public init(fields: [String: String], cardOrdinal: Int, isAnswer: Bool = false, frontSide: String? = nil,
                tags: String = "", deckName: String = "", cardName: String = "", notetypeName: String = "",
                flag: Int = 0, cardID: Int64 = 0) {
        self.fields = fields; self.cardOrdinal = cardOrdinal; self.isAnswer = isAnswer
        self.frontSide = frontSide; self.tags = tags; self.deckName = deckName; self.cardName = cardName
        self.notetypeName = notetypeName; self.flag = flag; self.cardID = cardID
    }
}

public enum TemplateRenderer {

    private static let emptyFieldRegex = try! NSRegularExpression(pattern: "^(?:\\s|&nbsp;|</?(?:br|div|p)\\s*/?>)*$", options: [.caseInsensitive])

    /// Um campo conta como vazio se só tiver espaços e quebras.
    public static func fieldIsEmpty(_ value: String) -> Bool {
        if value.isEmpty { return true }
        return emptyFieldRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static func specialFields(_ context: RenderContext) -> [String: String] {
        var special: [String: String] = [
            "Tags": context.tags.trimmingCharacters(in: .whitespaces),
            "Type": context.notetypeName,
            "Deck": context.deckName,
            "Subdeck": context.deckName.components(separatedBy: "::").last ?? context.deckName,
            "Card": context.cardName,
            "CardFlag": context.flag > 0 ? "flag\(context.flag)" : "",
            "CardID": String(context.cardID),
        ]
        if let front = context.frontSide { special["FrontSide"] = front }
        // Permite {{#c1}}…{{/c1}} em tipos cloze.
        special["c\(context.cardOrdinal + 1)"] = "1"
        return special
    }

    public static func render(_ template: ParsedTemplate, context: RenderContext) -> String {
        let special = specialFields(context)
        var hintCounter = 0

        func value(for key: String) -> String? {
            if let v = context.fields[key] { return v }
            if let v = special[key] { return v }
            // {{#c2}} em um card que não é o da omissão 2: vazio, não "campo desconhecido".
            if key.hasPrefix("c"), key.count > 1, key.dropFirst().allSatisfy(\.isNumber) { return "" }
            return nil
        }

        func emit(_ nodes: [TemplateNode]) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let text):
                    out += text
                case .replacement(let key, let filters):
                    // {{type:Campo}} e {{type:cloze:Campo}} viram marcadores resolvidos pela tela de estudo.
                    if filters.first == "type" {
                        if context.fields[key] != nil {
                            out += "[[" + (filters + [key]).joined(separator: ":") + "]]"
                        } else {
                            out += unknownField(key)
                        }
                        continue
                    }
                    if key.isEmpty && !filters.isEmpty {
                        // Filtros sem campo, ex.: {{tts-voices:}} — sem saída.
                        continue
                    }
                    guard var current = value(for: key) else {
                        out += unknownField(key)
                        continue
                    }
                    for filter in filters.reversed() {
                        hintCounter += 1
                        current = apply(filter: filter, to: current, fieldName: key, context: context,
                                        uniqueID: hintCounter)
                    }
                    out += current
                case .conditional(let key, let children):
                    if let v = value(for: key) {
                        if !fieldIsEmpty(v) { out += emit(children) }
                    } else {
                        out += unknownField(key)
                    }
                case .negated(let key, let children):
                    if let v = value(for: key) {
                        if fieldIsEmpty(v) { out += emit(children) }
                    } else {
                        out += unknownField(key)
                    }
                }
            }
            return out
        }

        return emit(template.nodes)
    }

    static func unknownField(_ key: String) -> String {
        "<span class=\"template-error\">{campo desconhecido: \(escape(key))}</span>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Filtros

    static func apply(filter: String, to text: String, fieldName: String, context: RenderContext, uniqueID: Int) -> String {
        let name: String
        let args: String
        if let space = filter.firstIndex(of: " ") {
            name = String(filter[filter.startIndex..<space])
            args = String(filter[filter.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = filter
            args = ""
        }

        switch name {
        case "text":
            return PlainText.strip(text)
        case "cloze":
            return Cloze.render(text, ordinal: context.cardOrdinal + 1, isAnswer: context.isAnswer)
        case "cloze-only":
            return Cloze.activeTexts(text, ordinal: context.cardOrdinal + 1).joined(separator: ", ")
        case "hint":
            if fieldIsEmpty(text) { return "" }
            let id = "hint\(context.cardID)_\(uniqueID)"
            return """
            <a class="hint" href="#" onclick="this.style.display='none';document.getElementById('\(id)').style.display='block';return false;" draggable="false">\(escape(fieldName))</a><div id="\(id)" class="hint" style="display: none">\(text)</div>
            """
        case "tts":
            let plain = PlainText.strip(Cloze.stripMarkup(text)).trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { return "" }
            // Primeiro argumento é o idioma; os demais são chave=valor.
            var parts = args.split(separator: " ").map(String.init)
            var header = "anki:tts"
            if let first = parts.first, !first.contains("=") {
                header += " lang=\(first)"
                parts.removeFirst()
            }
            for part in parts { header += " \(part)" }
            return "[\(header)]\(plain)[/anki:tts]"
        case "furigana":
            return Furigana.ruby(text)
        case "kana":
            return Furigana.kana(text)
        case "kanji":
            return Furigana.kanji(text)
        case "nc", "tts-voices":
            return text
        default:
            // Filtro desconhecido: mantém o texto.
            return text
        }
    }
}

/// Remoção simples de HTML, independente do módulo Core.
public enum PlainText {
    private static let tagRegex = try! NSRegularExpression(pattern: "(?si)<!--.*?-->|<style.*?>.*?</style>|<script.*?>.*?</script>|<[^>]*>")
    private static let breakRegex = try! NSRegularExpression(pattern: "(?i)<br\\s*/?>|</div>|</p>|</li>")
    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
    ]

    public static func strip(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        let range = NSRange(html.startIndex..., in: html)
        var text = tagRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    /// Como `strip`, mas preserva quebras de linha de `<br>` e blocos.
    public static func stripKeepingBreaks(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        let withBreaks = breakRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "\n")
        return strip(withBreaks)
    }
}

enum Furigana {
    private static let regex = try! NSRegularExpression(pattern: " ?([^ >]+?)\\[(.+?)\\]")

    private static func replace(_ text: String, with template: String) -> String {
        // Não mexe em [sound:...] nem em marcadores de TTS.
        guard text.contains("[") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let reading = ns.substring(with: match.range(at: 2))
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if reading.hasPrefix("sound:") || reading.hasPrefix("anki:") {
                out += ns.substring(with: match.range)
            } else {
                out += template
                    .replacingOccurrences(of: "$1", with: ns.substring(with: match.range(at: 1)))
                    .replacingOccurrences(of: "$2", with: reading)
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func ruby(_ text: String) -> String { replace(text, with: "<ruby><rb>$1</rb><rt>$2</rt></ruby>") }
    static func kana(_ text: String) -> String { replace(text, with: "$2") }
    static func kanji(_ text: String) -> String { replace(text, with: "$1") }
}
