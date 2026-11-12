import Foundation

/// Análise e renderização de omissões de palavras: `{{c1::texto::dica}}`, com aninhamento.
public enum Cloze {

    indirect enum Node: Equatable {
        case text(String)
        case cloze(ordinal: Int, children: [Node], hint: String?)
    }

    // MARK: Parser

    private enum Token {
        case open(Int)
        case close
        case text(String)
    }

    private static let openRegex = try! NSRegularExpression(pattern: "\\{\\{c(\\d+)::")

    private static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var position = 0
        let length = ns.length

        func pushText(_ range: NSRange) {
            if range.length > 0 { tokens.append(.text(ns.substring(with: range))) }
        }

        while position < length {
            let searchRange = NSRange(location: position, length: length - position)
            let openMatch = openRegex.firstMatch(in: text, range: searchRange)
            let closeRange = ns.range(of: "}}", range: searchRange)
            let openLocation = openMatch?.range.location ?? NSNotFound
            let closeLocation = closeRange.location

            if openLocation == NSNotFound && closeLocation == NSNotFound {
                pushText(searchRange)
                break
            }
            if openLocation < closeLocation, let openMatch {
                pushText(NSRange(location: position, length: openLocation - position))
                let ordinal = Int(ns.substring(with: openMatch.range(at: 1))) ?? 0
                tokens.append(.open(ordinal))
                position = openMatch.range.location + openMatch.range.length
            } else {
                pushText(NSRange(location: position, length: closeLocation - position))
                tokens.append(.close)
                position = closeLocation + 2
            }
        }
        return tokens
    }

    static func parse(_ text: String) -> [Node] {
        struct Frame {
            var ordinal: Int
            var nodes: [Node] = []
        }
        var root: [Node] = []
        var stack: [Frame] = []

        func append(_ node: Node) {
            if stack.isEmpty { root.append(node) } else { stack[stack.count - 1].nodes.append(node) }
        }

        for token in tokenize(text) {
            switch token {
            case .text(let string):
                append(.text(string))
            case .open(let ordinal):
                stack.append(Frame(ordinal: ordinal))
            case .close:
                guard let frame = stack.popLast() else {
                    append(.text("}}"))
                    continue
                }
                let (children, hint) = splitHint(frame.nodes)
                append(.cloze(ordinal: frame.ordinal, children: children, hint: hint))
            }
        }
        // Omissões não fechadas voltam a ser texto literal.
        while let frame = stack.popLast() {
            append(.text("{{c\(frame.ordinal)::"))
            for node in frame.nodes { append(node) }
        }
        return root
    }

    /// Separa a dica: o último nó de texto de nível superior que contenha "::".
    private static func splitHint(_ nodes: [Node]) -> ([Node], String?) {
        guard let last = nodes.last, case .text(let text) = last, let range = text.range(of: "::") else {
            return (nodes, nil)
        }
        var children = Array(nodes.dropLast())
        let before = String(text[text.startIndex..<range.lowerBound])
        let hint = String(text[range.upperBound...])
        if !before.isEmpty { children.append(.text(before)) }
        return (children, hint)
    }

    // MARK: Consultas

    /// Números de omissão presentes no texto (inclui aninhadas). Válidos: 1...499.
    public static func ordinals(in text: String) -> Set<Int> {
        guard text.contains("{{c") else { return [] }
        var result = Set<Int>()
        func walk(_ nodes: [Node]) {
            for node in nodes {
                if case .cloze(let ordinal, let children, _) = node {
                    if ordinal >= 1 && ordinal < 500 { result.insert(ordinal) }
                    walk(children)
                }
            }
        }
        walk(parse(text))
        return result
    }

    /// Próximo número livre para uma nova omissão.
    public static func nextOrdinal(in fields: [String]) -> Int {
        (fields.flatMap { ordinals(in: $0) }.max() ?? 0) + 1
    }

    // MARK: Renderização

    private static func plainText(_ nodes: [Node]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let text): return text
            case .cloze(_, let children, _): return plainText(children)
            }
        }.joined()
    }

    private static let imageOcclusionPrefix = "image-occlusion:"

    /// Converte `image-occlusion:rect:left=.1:top=.2` em atributos `data-*`.
    static func occlusionAttributes(_ text: String) -> String? {
        guard text.hasPrefix(imageOcclusionPrefix) else { return nil }
        let parts = text.dropFirst(imageOcclusionPrefix.count).components(separatedBy: ":")
        guard let shape = parts.first, !shape.isEmpty else { return nil }
        var attrs = "data-shape=\"\(escapeAttribute(shape))\""
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[part.startIndex..<eq].filter { $0.isLetter || $0.isNumber }
            let value = String(part[part.index(after: eq)...])
            if key.isEmpty { continue }
            attrs += " data-\(key.lowercased())=\"\(escapeAttribute(value))\""
        }
        return attrs
    }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Renderiza o campo para o card de número `ordinal` (1-based).
    public static func render(_ text: String, ordinal: Int, isAnswer: Bool) -> String {
        guard text.contains("{{c") else { return text }
        func emit(_ nodes: [Node], insideActive: Bool) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let string):
                    out += string
                case .cloze(let ord, let children, let hint):
                    let inner = plainText(children)
                    if let attrs = occlusionAttributes(inner) {
                        let cls: String
                        if ord == ordinal { cls = isAnswer ? "cloze-highlight" : "cloze" } else { cls = "cloze-inactive" }
                        out += "<div class=\"\(cls)\" data-ordinal=\"\(ord)\" \(attrs)></div>"
                        continue
                    }
                    if ord == ordinal {
                        if isAnswer {
                            out += "<span class=\"cloze\" data-ordinal=\"\(ord)\">"
                                + emit(children, insideActive: true) + "</span>"
                        } else {
                            let shown = (hint?.isEmpty == false) ? hint! : "..."
                            out += "<span class=\"cloze\" data-cloze=\"\(escapeAttribute(emit(children, insideActive: true)))\" data-ordinal=\"\(ord)\">[\(shown)]</span>"
                        }
                    } else if insideActive {
                        out += emit(children, insideActive: true)
                    } else {
                        out += "<span class=\"cloze-inactive\" data-ordinal=\"\(ord)\">"
                            + emit(children, insideActive: false) + "</span>"
                    }
                }
            }
            return out
        }
        return emit(parse(text), insideActive: false)
    }

    /// Textos das omissões ativas do card (para `{{type:cloze:Campo}}` e `cloze-only`).
    public static func activeTexts(_ text: String, ordinal: Int) -> [String] {
        var result: [String] = []
        func walk(_ nodes: [Node]) {
            for node in nodes {
                if case .cloze(let ord, let children, _) = node {
                    if ord == ordinal { result.append(plainText(children)) } else { walk(children) }
                }
            }
        }
        walk(parse(text))
        return result
    }

    /// Remove a marcação de omissão, deixando só o texto (para exibição no navegador).
    public static func stripMarkup(_ text: String) -> String {
        guard text.contains("{{c") else { return text }
        return plainText(parse(text))
    }
}
