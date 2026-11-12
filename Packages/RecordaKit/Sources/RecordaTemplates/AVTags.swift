import Foundation

/// Áudio referenciado por um card: arquivo (`[sound:x.mp3]`) ou fala sintetizada (`{{tts ...}}`).
public enum AVTag: Sendable, Equatable {
    case sound(filename: String)
    case tts(text: String, lang: String?, voices: [String], speed: Double)
}

public enum AVTags {
    private static let regex = try! NSRegularExpression(
        pattern: "\\[sound:([^\\]]+)\\]|\\[anki:tts([^\\]]*)\\](.*?)\\[/anki:tts\\]",
        options: [.dotMatchesLineSeparators])

    /// Extrai as tags de áudio e as troca por botões de reprodução.
    /// `side` ("q" ou "a") entra no identificador do botão: `recordaPlay('q', 0)`.
    public static func extract(from html: String, side: String) -> (html: String, tags: [AVTag]) {
        guard html.contains("[sound:") || html.contains("[anki:tts") else { return (html, []) }
        let ns = html as NSString
        var out = ""
        var tags: [AVTag] = []
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            if match.range(at: 1).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 1))
                tags.append(.sound(filename: decode(name)))
            } else {
                let args = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
                let text = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
                var lang: String?
                var voices: [String] = []
                var speed = 1.0
                for part in args.split(separator: " ") {
                    let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { continue }
                    switch pieces[0] {
                    case "lang": lang = pieces[1].replacingOccurrences(of: "_", with: "-")
                    case "voices": voices = pieces[1].split(separator: ",").map(String.init)
                    case "speed": speed = Double(pieces[1]) ?? 1.0
                    default: break
                    }
                }
                tags.append(.tts(text: text, lang: lang, voices: voices, speed: speed))
            }
            let index = tags.count - 1
            out += """
            <a class="replay-button soundLink" href="#" onclick="recordaPlay('\(side)', \(index)); return false;" draggable="false" aria-label="Tocar áudio"><svg class="playImage" viewBox="0 0 64 64" version="1.1"><circle cx="32" cy="32" r="29"></circle><path d="M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z"></path></svg></a>
            """
        }
        out += ns.substring(from: last)
        return (out, tags)
    }

    /// Remove as tags de áudio sem gerar botões (navegador, busca).
    public static func strip(_ html: String) -> String {
        guard html.contains("[sound:") || html.contains("[anki:tts") else { return html }
        return regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
    }

    private static func decode(_ name: String) -> String {
        name.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

/// Converte a marcação LaTeX legada do Anki em delimitadores do MathJax.
public enum LatexMarkup {
    private static let patterns: [(NSRegularExpression, String, String)] = [
        (try! NSRegularExpression(pattern: "\\[\\$\\$\\](.+?)\\[/\\$\\$\\]", options: [.dotMatchesLineSeparators, .caseInsensitive]), "\\[", "\\]"),
        (try! NSRegularExpression(pattern: "\\[\\$\\](.+?)\\[/\\$\\]", options: [.dotMatchesLineSeparators, .caseInsensitive]), "\\(", "\\)"),
        (try! NSRegularExpression(pattern: "\\[latex\\](.+?)\\[/latex\\]", options: [.dotMatchesLineSeparators, .caseInsensitive]), "\\(", "\\)"),
    ]

    public static func toMathJax(_ html: String) -> String {
        guard html.contains("[$") || html.range(of: "[latex]", options: .caseInsensitive) != nil else { return html }
        var text = html
        for (regex, open, close) in patterns {
            let ns = text as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                var body = ns.substring(with: match.range(at: 1))
                // O editor pode ter inserido quebras HTML dentro da fórmula.
                body = body.replacingOccurrences(of: "<br>", with: "\n")
                    .replacingOccurrences(of: "<br />", with: "\n")
                    .replacingOccurrences(of: "<br/>", with: "\n")
                out += open + body + close
                last = match.range.location + match.range.length
            }
            out += ns.substring(from: last)
            text = out
        }
        return text
    }
}
